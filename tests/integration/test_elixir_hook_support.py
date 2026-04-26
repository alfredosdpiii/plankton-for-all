"""Integration tests for Elixir/Phoenix hook support."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / ".plankton" / "hooks" / "multi_linter.sh"


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def _write_elixir_config(project_dir: Path) -> None:
    config = {
        "languages": {
            "python": False,
            "elixir": True,
            "shell": False,
            "yaml": False,
            "json": False,
            "toml": False,
            "dockerfile": False,
            "markdown": False,
            "typescript": False,
        }
    }
    config_dir = project_dir / ".plankton"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")


def _make_mix_project(tmp_path: Path) -> Path:
    project_dir = tmp_path / "demo"
    (project_dir / "lib").mkdir(parents=True)
    (project_dir / "mix.exs").write_text("defmodule Demo.MixProject do\nend\n", encoding="utf-8")
    (project_dir / ".formatter.exs").write_text("[]\n", encoding="utf-8")
    _write_elixir_config(project_dir)
    return project_dir


def _install_fake_mix(bin_dir: Path) -> None:
    _write_executable(
        bin_dir / "mix",
        """#!/usr/bin/env bash
set -euo pipefail

cmd=\"${1:-}\"
shift || true

case \"${cmd}\" in
  help)
    [[ \"${1:-}\" == \"credo\" ]] && exit 0
    exit 1
    ;;
  format)
    if [[ \"${1:-}\" == \"--check-formatted\" ]]; then
      shift
    fi
    target=\"${1:-}\"
    if [[ \"${target}\" == *\"broken.heex\" ]]; then
      echo \"** (SyntaxError) broken.heex:1:1: unexpected token: <\" >&2
      exit 1
    fi
    exit 0
    ;;
  credo)
    cat <<'JSON'
{"explanations":[{"check":"Credo.Check.Readability.ModuleDoc","column":1,"filename":"lib/demo.ex","line_no":1,"message":"Module docs are required"}]}
JSON
    exit 1
    ;;
  *)
    echo \"unexpected mix command: ${cmd}\" >&2
    exit 1
    ;;
esac
""",
    )


def _run_hook(project_dir: Path, file_path: Path) -> subprocess.CompletedProcess[str]:
    fake_bin = project_dir / "fake-bin"
    fake_bin.mkdir(exist_ok=True)
    _install_fake_mix(fake_bin)

    env = os.environ.copy()
    env["PLANKTON_PROJECT_DIR"] = str(project_dir)
    env["HOOK_SKIP_SUBPROCESS"] = "1"
    env["PATH"] = f"{fake_bin}:{env['PATH']}"

    payload = json.dumps({"tool_input": {"file_path": str(file_path)}})
    return subprocess.run(
        ["bash", str(HOOK)],
        input=payload,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def _extract_hook_payload(stderr: str) -> list[dict[str, object]]:
    prefix = "[hook] "
    start = stderr.find(prefix)
    if start == -1:
        raise AssertionError(f"No hook payload found in stderr: {stderr!r}")
    payload = stderr[start + len(prefix) :].strip()
    return json.loads(payload)


def test_multi_linter_collects_credo_json_for_elixir_files(tmp_path: Path) -> None:
    project_dir = _make_mix_project(tmp_path)
    file_path = project_dir / "lib" / "demo.ex"
    file_path.write_text("defmodule Demo do\nend\n", encoding="utf-8")

    result = _run_hook(project_dir, file_path)

    assert result.returncode == 2
    violations = _extract_hook_payload(result.stderr)
    assert violations == [
        {
            "line": 1,
            "column": 1,
            "code": "Credo.Check.Readability.ModuleDoc",
            "message": "Module docs are required",
            "linter": "credo",
        }
    ]


def test_multi_linter_surfaces_mix_format_failures_for_heex_files(tmp_path: Path) -> None:
    project_dir = _make_mix_project(tmp_path)
    component_dir = project_dir / "lib" / "demo_web" / "components"
    component_dir.mkdir(parents=True)
    file_path = component_dir / "broken.heex"
    file_path.write_text("<div><%= broken </div>\n", encoding="utf-8")

    result = _run_hook(project_dir, file_path)

    assert result.returncode == 2
    violations = _extract_hook_payload(result.stderr)
    assert violations == [
        {
            "line": 1,
            "column": 1,
            "code": "MIX_FORMAT",
            "message": "** (SyntaxError) broken.heex:1:1: unexpected token: <",
            "linter": "mix format",
        }
    ]
