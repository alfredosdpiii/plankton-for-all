import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { withFileMutationQueue } from "@mariozechner/pi-coding-agent";
import { resolve } from "node:path";
import {
  formatConfigSummary,
  loadPlanktonConfig,
  readConfigForWrite,
  resolvePlanktonContext,
  writeConfig,
} from "./config.js";
import { runHook, summarizeLintResult } from "./lint.js";
import type { PlanktonState } from "./state.js";

function sendText(pi: ExtensionAPI, content: string, ctx?: { hasUI?: boolean }): void {
  pi.sendMessage({ customType: "text", content, display: true });
  if (ctx?.hasUI === false) console.log(content);
}

function firstArg(args: string): string | undefined {
  const trimmed = args.trim();
  if (!trimmed) return undefined;
  return trimmed.split(/\s+/)[0];
}

function toggleLanguage(config: any, language: string): boolean {
  config.languages = typeof config.languages === "object" && config.languages !== null ? config.languages : {};
  const current = config.languages[language];
  let next: boolean;
  if (typeof current === "boolean") {
    next = !current;
    config.languages[language] = next;
  } else if (typeof current === "object" && current !== null) {
    next = current.enabled === false;
    current.enabled = next;
  } else {
    next = true;
    config.languages[language] = true;
  }
  return next;
}

export function registerPlanktonCommands(pi: ExtensionAPI, state: PlanktonState): void {
  pi.registerCommand("plankton-status", {
    description: "Show Plankton configuration, hook resolution, and current-branch stats.",
    handler: async (_args, ctx) => {
      const context = await resolvePlanktonContext(ctx.cwd);
      const { config, warnings } = await loadPlanktonConfig(context);
      const lines = [formatConfigSummary(context, config), state.format()];
      if (warnings.length > 0) lines.push("Warnings:\n" + warnings.map((warning) => `  - ${warning}`).join("\n"));
      const message = lines.join("\n\n");
      sendText(pi, message, ctx);
      if (ctx.hasUI) ctx.ui.notify("Plankton status posted.", "info");
    },
  });

  pi.registerCommand("plankton-lint", {
    description: "Run Plankton linting for a file.",
    handler: async (args, ctx) => {
      const target = firstArg(args);
      if (!target) {
        sendText(pi, "Usage: /plankton-lint <file>", ctx);
        return;
      }

      const context = await resolvePlanktonContext(ctx.cwd);
      if (context.noOp) {
        sendText(pi, "No .plankton/config.json found; Plankton is inactive.", ctx);
        return;
      }

      const { config } = await loadPlanktonConfig(context);
      const absPath = resolve(ctx.cwd, target.startsWith("@") ? target.slice(1) : target);
      const payload = JSON.stringify({ tool_name: "Write", tool_input: { file_path: absPath } });
      const result = await runHook(
        "multi_linter.sh",
        payload,
        { PLANKTON_DELEGATE_CMD: String(config.subprocess?.delegate_cmd ?? "pi") },
        ctx.signal,
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
      sendText(pi, summary.message, ctx);
    },
  });

  pi.registerCommand("plankton-toggle", {
    description: "Toggle a language in .plankton/config.json.",
    handler: async (args, ctx) => {
      const language = firstArg(args);
      if (!language) {
        sendText(pi, "Usage: /plankton-toggle <language>", ctx);
        return;
      }

      const context = await resolvePlanktonContext(ctx.cwd);
      if (context.noOp || !context.configPath) {
        sendText(pi, "No .plankton/config.json found; Plankton is inactive.", ctx);
        return;
      }

      const enabled = await withFileMutationQueue(context.configPath, async () => {
        const config = await readConfigForWrite(context);
        const next = toggleLanguage(config, language);
        await writeConfig(context, config);
        return next;
      });

      sendText(pi, `Plankton ${language} linting ${enabled ? "enabled" : "disabled"}.`, ctx);
      if (ctx.hasUI) ctx.ui.notify(`Plankton ${language}: ${enabled ? "enabled" : "disabled"}`, "info");
    },
  });
}
