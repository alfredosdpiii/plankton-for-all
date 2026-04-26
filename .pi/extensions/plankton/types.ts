export interface PlanktonContext {
  root: string;
  configPath?: string;
  projectHooksDir: string;
  bundledHooksDir: string;
  noOp: boolean;
  initialized?: boolean;
  gitHooksInstalled?: string[];
  gitHooksSkipped?: string[];
}

export interface PlanktonConfig {
  tested_version?: string;
  cc_tested_version?: string;
  hook_enabled?: boolean;
  _comment?: string;
  languages?: Record<string, unknown>;
  protected_files?: string[];
  security_linter_exclusions?: string[];
  phases?: Record<string, unknown>;
  subprocess?: {
    settings_file?: string;
    delegate_cmd?: string;
    correction_model?: string;
    global_model_override?: string | null;
    [key: string]: unknown;
  };
  jscpd?: Record<string, unknown>;
  package_managers?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface LoadedPlanktonConfig {
  config: PlanktonConfig;
  warnings: string[];
}

export interface HookRunResult {
  scriptPath: string;
  code: number | null;
  signal: NodeJS.Signals | null;
  stdoutRaw: string;
  stderrRaw: string;
  stdout: string;
  stderr: string;
  json?: Record<string, unknown>;
  parseError?: string;
  timedOut: boolean;
  aborted: boolean;
  ok: boolean;
}

export interface LintSummary {
  filePath: string;
  clean: boolean;
  message: string;
  code: number | null;
  timedOut: boolean;
  aborted: boolean;
}

export interface PlanktonStats {
  lintRuns: number;
  cleanRuns: number;
  violationRuns: number;
  blockedToolCalls: number;
  hookFailures: number;
  lastMessage?: string;
}
