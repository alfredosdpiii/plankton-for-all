import { access } from "node:fs/promises";
import { join } from "node:path";
import { spawn } from "node:child_process";
import type { HookRunResult, LintSummary, PlanktonContext } from "./types.js";

const PRE_TOOL_TIMEOUT_MS = 5_000;
const POST_LINT_TIMEOUT_MS = 600_000;
const KILL_GRACE_MS = 5_000;
const DISPLAY_LIMIT = 8_000;

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function resolveScript(scriptName: string, context: PlanktonContext): Promise<string> {
  const projectScript = join(context.projectHooksDir, scriptName);
  if (await exists(projectScript)) return projectScript;

  const bundledScript = join(context.bundledHooksDir, scriptName);
  if (await exists(bundledScript)) return bundledScript;

  throw new Error(`Plankton hook script not found: ${scriptName}`);
}

function timeoutForScript(scriptName: string): number {
  return scriptName === "multi_linter.sh" ? POST_LINT_TIMEOUT_MS : PRE_TOOL_TIMEOUT_MS;
}

function truncate(value: string): string {
  if (value.length <= DISPLAY_LIMIT) return value;
  return `${value.slice(0, DISPLAY_LIMIT)}\n[truncated ${value.length - DISPLAY_LIMIT} chars]`;
}

function cleanEnv(extraEnv: Record<string, string | undefined>): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries({ ...process.env, ...extraEnv })) {
    if (value !== undefined) env[key] = value;
  }
  return env;
}

function parseJson(stdout: string): { json?: Record<string, unknown>; parseError?: string } {
  const trimmed = stdout.trim();
  if (!trimmed) return { parseError: "Hook produced empty stdout." };
  try {
    const parsed = JSON.parse(trimmed) as unknown;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return { json: parsed as Record<string, unknown> };
    }
    return { parseError: "Hook stdout JSON was not an object." };
  } catch (error) {
    return { parseError: error instanceof Error ? error.message : String(error) };
  }
}

export async function runHook(
  scriptName: string,
  jsonInput: string,
  env: Record<string, string | undefined>,
  signal: AbortSignal | undefined,
  context: PlanktonContext,
  timeoutMs = timeoutForScript(scriptName),
): Promise<HookRunResult> {
  const scriptPath = await resolveScript(scriptName, context);

  return new Promise<HookRunResult>((resolve) => {
    let stdoutRaw = "";
    let stderrRaw = "";
    let timedOut = false;
    let aborted = false;
    let settled = false;
    let sigkillTimer: NodeJS.Timeout | undefined;

    const child = spawn("bash", [scriptPath], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
      cwd: context.root,
      env: cleanEnv({
        PLANKTON_PROJECT_DIR: context.root,
        PLANKTON_CONFIG: context.configPath,
        ...env,
      }),
    });

    const killProcessGroup = (reason: "abort" | "timeout") => {
      if (settled) return;
      if (reason === "abort") aborted = true;
      if (reason === "timeout") timedOut = true;
      if (child.pid === undefined) {
        child.kill("SIGTERM");
        return;
      }

      try {
        process.kill(-child.pid, "SIGTERM");
      } catch {
        try {
          child.kill("SIGTERM");
        } catch {
          // Already exited.
        }
      }

      sigkillTimer = setTimeout(() => {
        if (settled || child.pid === undefined) return;
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch {
          try {
            child.kill("SIGKILL");
          } catch {
            // Already exited.
          }
        }
      }, KILL_GRACE_MS);
      sigkillTimer.unref?.();
    };

    const timeoutTimer = setTimeout(() => killProcessGroup("timeout"), timeoutMs);
    timeoutTimer.unref?.();

    const abortListener = () => killProcessGroup("abort");
    if (signal?.aborted) abortListener();
    else signal?.addEventListener("abort", abortListener, { once: true });

    child.stdout.on("data", (chunk: Buffer) => {
      stdoutRaw += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderrRaw += chunk.toString("utf8");
    });

    child.on("error", (error) => {
      stderrRaw += `\n${error instanceof Error ? error.message : String(error)}`;
    });

    child.on("close", (code, childSignal) => {
      settled = true;
      clearTimeout(timeoutTimer);
      if (sigkillTimer) clearTimeout(sigkillTimer);
      signal?.removeEventListener("abort", abortListener);

      const { json, parseError } = parseJson(stdoutRaw);
      resolve({
        scriptPath,
        code,
        signal: childSignal,
        stdoutRaw,
        stderrRaw,
        stdout: truncate(stdoutRaw),
        stderr: truncate(stderrRaw),
        json,
        parseError,
        timedOut,
        aborted,
        ok: code === 0 || code === 2,
      });
    });

    child.stdin.end(jsonInput);
  });
}

export function summarizeLintResult(filePath: string, result: HookRunResult): LintSummary {
  const systemMessage = typeof result.json?.systemMessage === "string" ? result.json.systemMessage : undefined;
  const clean = result.code === 0 && !systemMessage;
  const fallback = result.parseError
    ? `Plankton hook completed but returned invalid JSON: ${result.parseError}`
    : result.stderr.trim() || result.stdout.trim() || "Plankton lint completed.";
  return {
    filePath,
    clean,
    message: systemMessage ?? fallback,
    code: result.code,
    timedOut: result.timedOut,
    aborted: result.aborted,
  };
}
