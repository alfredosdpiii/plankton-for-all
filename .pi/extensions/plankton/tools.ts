import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { withFileMutationQueue } from "@mariozechner/pi-coding-agent";
import { StringEnum } from "@mariozechner/pi-ai";
import { Type } from "typebox";
import { resolve } from "node:path";
import {
  loadPlanktonConfig,
  readConfigForWrite,
  resolvePlanktonContext,
  setValidatedConfigValue,
  writeConfig,
} from "./config.js";
import { runHook, summarizeLintResult } from "./lint.js";
import { renderLintCall, renderLintResult } from "./render.js";
import type { PlanktonState } from "./state.js";

function normalizePath(cwd: string, value: string): string {
  const path = value.startsWith("@") ? value.slice(1) : value;
  return resolve(cwd, path);
}

function textResult(text: string, details: Record<string, unknown> = {}) {
  return { content: [{ type: "text" as const, text }], details };
}

export function registerPlanktonTools(pi: ExtensionAPI, state: PlanktonState): void {
  pi.registerTool({
    name: "plankton_lint",
    label: "Plankton Lint",
    description: "Run Plankton linting for a single file and return a compact summary.",
    promptSnippet: "Run Plankton linting for one project file.",
    parameters: Type.Object({
      path: Type.String({ description: "File path to lint." }),
    }, { additionalProperties: false }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const context = await resolvePlanktonContext(ctx.cwd);
      if (context.noOp) return textResult("No project marker found; Plankton was not auto-initialized.", { clean: true });

      const { config } = await loadPlanktonConfig(context);
      const absPath = normalizePath(ctx.cwd, params.path);
      const payload = JSON.stringify({ tool_name: "Write", tool_input: { file_path: absPath } });
      const result = await runHook(
        "multi_linter.sh",
        payload,
        { PLANKTON_DELEGATE_CMD: String(config.subprocess?.delegate_cmd ?? "pi") },
        signal,
        context,
      );
      const summary = summarizeLintResult(absPath, result);

      state.record(pi, {
        lintRuns: 1,
        cleanRuns: summary.clean ? 1 : 0,
        violationRuns: summary.clean ? 0 : 1,
        hookFailures: result.ok && !result.parseError ? 0 : 1,
        lastMessage: summary.message,
      });

      return textResult(summary.message, {
        clean: summary.clean,
        summary: summary.message,
        systemMessage: summary.message,
        code: summary.code,
        timedOut: summary.timedOut,
        aborted: summary.aborted,
      });
    },
    renderCall: renderLintCall,
    renderResult: renderLintResult,
  });

  pi.registerTool({
    name: "plankton_config",
    label: "Plankton Config",
    description: "Read or update safe Plankton configuration keys.",
    promptSnippet: "Read or safely update Plankton configuration.",
    parameters: Type.Object({
      action: StringEnum(["get", "set"] as const),
      key: Type.String({ description: "Allowed config key. Dotted paths and prototype keys are rejected." }),
      value: Type.Optional(Type.Any()),
    }, { additionalProperties: false }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const context = await resolvePlanktonContext(ctx.cwd);
      if (context.noOp || !context.configPath) {
        return textResult("No project marker found; Plankton was not auto-initialized.");
      }

      if (params.action === "get") {
        const { config } = await loadPlanktonConfig(context);
        const key = params.key;
        const value = key in config ? config[key] : config.languages?.[key];
        return textResult(JSON.stringify(value ?? null, null, 2), { key, value });
      }

      const updated = await withFileMutationQueue(context.configPath, async () => {
        const config = await readConfigForWrite(context);
        setValidatedConfigValue(config, params.key, params.value);
        await writeConfig(context, config);
        return config;
      });

      return textResult(`Updated .plankton/config.json key '${params.key}'.`, { key: params.key, value: params.value, config: updated });
    },
  });
}
