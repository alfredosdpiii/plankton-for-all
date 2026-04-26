import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import type { PlanktonStats } from "./types.js";

const emptyStats = (): PlanktonStats => ({
  lintRuns: 0,
  cleanRuns: 0,
  violationRuns: 0,
  blockedToolCalls: 0,
  hookFailures: 0,
});

export class PlanktonState {
  stats: PlanktonStats = emptyStats();

  reconstruct(ctx: any): void {
    const next = emptyStats();
    const entries = typeof ctx?.sessionManager?.getBranch === "function"
      ? ctx.sessionManager.getBranch()
      : [];

    for (const entry of entries) {
      if (entry?.type !== "custom" || entry?.customType !== "plankton-stats") continue;
      const data = entry.data as Partial<PlanktonStats> | undefined;
      next.lintRuns += Number(data?.lintRuns ?? 0);
      next.cleanRuns += Number(data?.cleanRuns ?? 0);
      next.violationRuns += Number(data?.violationRuns ?? 0);
      next.blockedToolCalls += Number(data?.blockedToolCalls ?? 0);
      next.hookFailures += Number(data?.hookFailures ?? 0);
      if (typeof data?.lastMessage === "string") next.lastMessage = data.lastMessage;
    }

    this.stats = next;
  }

  record(pi: ExtensionAPI, delta: Partial<PlanktonStats>): void {
    const entry: PlanktonStats = {
      lintRuns: delta.lintRuns ?? 0,
      cleanRuns: delta.cleanRuns ?? 0,
      violationRuns: delta.violationRuns ?? 0,
      blockedToolCalls: delta.blockedToolCalls ?? 0,
      hookFailures: delta.hookFailures ?? 0,
      lastMessage: delta.lastMessage,
    };

    this.stats.lintRuns += entry.lintRuns;
    this.stats.cleanRuns += entry.cleanRuns;
    this.stats.violationRuns += entry.violationRuns;
    this.stats.blockedToolCalls += entry.blockedToolCalls;
    this.stats.hookFailures += entry.hookFailures;
    if (entry.lastMessage) this.stats.lastMessage = entry.lastMessage;

    pi.appendEntry("plankton-stats", entry);
  }

  format(): string {
    return [
      "Session stats (current branch):",
      `  lint runs: ${this.stats.lintRuns}`,
      `  clean: ${this.stats.cleanRuns}`,
      `  violations: ${this.stats.violationRuns}`,
      `  blocked tool calls: ${this.stats.blockedToolCalls}`,
      `  hook failures: ${this.stats.hookFailures}`,
      this.stats.lastMessage ? `  last: ${this.stats.lastMessage}` : undefined,
    ].filter(Boolean).join("\n");
  }
}
