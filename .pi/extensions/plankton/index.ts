import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { withFileMutationQueue } from "@mariozechner/pi-coding-agent";
import { resolve } from "node:path";
import { getEnabledLanguages, loadPlanktonConfig, resolvePlanktonContext } from "./config.js";
import { runHook, summarizeLintResult } from "./lint.js";
import { registerPlanktonCommands } from "./commands.js";
import { registerPlanktonTools } from "./tools.js";
import { PlanktonState } from "./state.js";

const toolNameMap: Record<string, string> = {
  write: "Write",
  edit: "Edit",
};

function toolPath(input: any): string | undefined {
  return typeof input?.path === "string" ? input.path : undefined;
}

function textParts(content: unknown): Array<{ type: "text"; text: string }> {
  if (!Array.isArray(content)) return [];
  return content.filter((part): part is { type: "text"; text: string } => part?.type === "text" && typeof part.text === "string");
}

function appendText(content: unknown, text: string): Array<{ type: "text"; text: string }> {
  const existing = textParts(content);
  if (existing.length === 0) return [{ type: "text", text }];
  return [{ type: "text", text: `${existing.map((part) => part.text).join("\n")}\n\n[Plankton] ${text}` }];
}

function blockReason(result: Awaited<ReturnType<typeof runHook>>, fallback: string): string | undefined {
  if (result.parseError || !result.ok) return undefined;
  if (result.json?.decision === "block") {
    return typeof result.json.reason === "string" ? result.json.reason : fallback;
  }
  return undefined;
}

const loadedKey = "__planktonPiExtensionLoaded";

export default function (pi: ExtensionAPI) {
  const globals = globalThis as typeof globalThis & Record<string, boolean | undefined>;
  if (globals[loadedKey]) return;
  globals[loadedKey] = true;

  const state = new PlanktonState();

  registerPlanktonCommands(pi, state);
  registerPlanktonTools(pi, state);

  pi.on("session_shutdown", async () => {
    globals[loadedKey] = false;
  });

  pi.on("session_start", async (_event, ctx) => {
    state.reconstruct(ctx);
    const context = await resolvePlanktonContext(ctx.cwd);
    if (context.initialized && ctx.hasUI) {
      const gitHookSuffix = context.gitHooksInstalled?.length
        ? ` Git hooks: ${context.gitHooksInstalled.join(", ")}.`
        : "";
      ctx.ui.notify(`Plankton initialized at ${context.configPath}.${gitHookSuffix}`, "info");
    }
  });

  pi.on("session_tree", async (_event, ctx) => {
    state.reconstruct(ctx);
  });

  pi.on("tool_call", async (event, ctx) => {
    const context = await resolvePlanktonContext(ctx.cwd);
    if (context.noOp) return undefined;

    const { config } = await loadPlanktonConfig(context);
    const delegate = String(config.subprocess?.delegate_cmd ?? "pi");

    if (event.toolName === "write" || event.toolName === "edit") {
      const path = toolPath(event.input);
      if (!path) return undefined;
      try {
        const result = await runHook(
          "protect_linter_configs.sh",
          JSON.stringify({ tool_input: { file_path: path } }),
          { PLANKTON_DELEGATE_CMD: delegate },
          ctx.signal,
          context,
        );
        const reason = blockReason(result, "Protected file blocked by Plankton.");
        if (reason) {
          state.record(pi, { blockedToolCalls: 1, lastMessage: reason });
          return { block: true, reason };
        }
      } catch {
        return undefined;
      }
    }

    if (event.toolName === "bash") {
      const command = typeof event.input?.command === "string" ? event.input.command : undefined;
      if (!command) return undefined;
      try {
        const result = await runHook(
          "enforce_package_managers.sh",
          JSON.stringify({ tool_input: { command } }),
          { PLANKTON_DELEGATE_CMD: delegate },
          ctx.signal,
          context,
        );
        const reason = blockReason(result, "Package manager command blocked by Plankton.");
        if (reason) {
          state.record(pi, { blockedToolCalls: 1, lastMessage: reason });
          return { block: true, reason };
        }
      } catch {
        return undefined;
      }
    }

    return undefined;
  });

  pi.on("tool_result", async (event, ctx) => {
    if (event.isError) return undefined;
    if (event.toolName !== "write" && event.toolName !== "edit") return undefined;

    const path = toolPath(event.input);
    if (!path) return undefined;

    const context = await resolvePlanktonContext(ctx.cwd);
    if (context.noOp) return undefined;

    const { config } = await loadPlanktonConfig(context);
    const absPath = resolve(ctx.cwd, path.startsWith("@") ? path.slice(1) : path);

    const result = await withFileMutationQueue(absPath, async () => runHook(
      "multi_linter.sh",
      JSON.stringify({ tool_name: toolNameMap[event.toolName] ?? event.toolName, tool_input: { file_path: absPath } }),
      { PLANKTON_DELEGATE_CMD: String(config.subprocess?.delegate_cmd ?? "pi") },
      ctx.signal,
      context,
    ));

    const summary = summarizeLintResult(absPath, result);
    state.record(pi, {
      lintRuns: 1,
      cleanRuns: summary.clean ? 1 : 0,
      violationRuns: summary.clean ? 0 : 1,
      hookFailures: result.ok && !result.parseError ? 0 : 1,
      lastMessage: summary.message,
    });

    if (!summary.message || summary.clean) return undefined;
    return { content: appendText(event.content, summary.message) };
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const context = await resolvePlanktonContext(ctx.cwd);
    if (context.noOp) return undefined;

    const marker = "[Plankton Pi Rules]";
    if (event.systemPrompt.includes(marker)) return undefined;

    const { config } = await loadPlanktonConfig(context);
    const languages = getEnabledLanguages(config).join(", ") || "none";
    const protectedFiles = Array.isArray(config.protected_files) ? config.protected_files.join(", ") : "configured linter files";
    const packageManagers = config.package_managers ?? {};

    const prompt = [
      marker,
      `Plankton is active for this project at ${context.configPath}.`,
      `Enabled lint languages: ${languages}.`,
      `Protected config files: ${protectedFiles}. Do not edit protected lint configs to bypass violations.`,
      `Use enforced package managers: python=${String((packageManagers as any).python ?? "uv")}, javascript=${String((packageManagers as any).javascript ?? "bun")}.`,
      "Plankton runs automatically after write/edit tool calls; fix code issues reported in tool results.",
    ].join("\n");

    return { systemPrompt: `${event.systemPrompt}\n\n${prompt}` };
  });
}
