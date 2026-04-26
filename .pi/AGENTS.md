# Plankton Linting Agent

This project uses Plankton for multi-language linting. The Pi extension at
`.pi/extensions/plankton/` runs linting hooks after file edits and blocks
modifications to protected config files.

## Linting behavior

- After each Write/Edit, the linter runs and reports violations as system messages
- Fix the code based on violation messages; do not modify linter config files
- Protected files (`.ruff.toml`, `biome.json`, etc.) are immutable
- Use `uv` instead of pip/poetry for Python packages
- Use `bun` instead of npm/yarn/pnpm for JavaScript packages

## Elixir/Phoenix enforcement

Phoenix projects get additional checks beyond `mix format`:

- **Credo** (`credo: true`): Static code analysis for consistency, design,
  readability, and refactoring opportunities. Runs per file.
- **Sobelow** (`sobelow: true`): Phoenix-specific security scanner. Catches XSS,
  SQL injection, CSRF bypass, hardcoded secrets, directory traversal. Runs once
  per session on first Elixir file edit (project-level scan).
- **Compile warnings** (`mix_compile_warnings: false`): Runs `mix compile
  --warnings-as-errors`. Catches unused variables, missing functions, deprecated
  calls. Off by default (can be slow on large projects).

Elixir config is structured like TypeScript:
```json
"elixir": {
  "enabled": true,
  "credo": true,
  "sobelow": true,
  "mix_compile_warnings": false
}
```

Protected Phoenix config files: `.formatter.exs`, `.credo.exs`, `.sobelow-conf`, `.sobelow-skips`

## Config

Linting config lives in `.plankton/config.json`.
