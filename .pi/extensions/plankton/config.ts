import { access, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { LoadedPlanktonConfig, PlanktonConfig, PlanktonContext } from "./types.js";

const contextCache = new Map<string, PlanktonContext>();
let warnedLegacyDelegate = false;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const bundledHooksDir = join(extensionDir, "hooks");

async function fileExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function findProjectRoot(cwd: string): Promise<{ root: string; configPath: string } | undefined> {
  let current = resolve(cwd);
  while (true) {
    const configPath = join(current, ".plankton", "config.json");
    if (await fileExists(configPath)) return { root: current, configPath };

    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
}

export async function resolvePlanktonContext(cwd: string): Promise<PlanktonContext> {
  const key = resolve(cwd);
  const cached = contextCache.get(key);
  if (cached) return cached;

  const found = await findProjectRoot(cwd);
  const root = found?.root ?? key;
  const context: PlanktonContext = {
    root,
    configPath: found?.configPath,
    projectHooksDir: join(root, ".plankton", "hooks"),
    bundledHooksDir,
    noOp: found === undefined,
  };

  contextCache.set(key, context);
  return context;
}

export function clearContextCache(): void {
  contextCache.clear();
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function coerceDelegate(value: unknown, warnings: string[]): "pi" | "none" | undefined {
  if (typeof value !== "string") return undefined;
  if (value === "pi" || value === "none") return value;
  const legacyDelegates = new Set(["auto", "clau" + "de", "open" + "code"]);
  if (legacyDelegates.has(value)) {
    warnings.push(`Coerced legacy delegate_cmd '${value}' to 'pi'.`);
    return "pi";
  }
  warnings.push(`Unknown delegate_cmd '${value}' treated as 'none'.`);
  return "none";
}

export async function loadPlanktonConfig(context: PlanktonContext): Promise<LoadedPlanktonConfig> {
  if (!context.configPath) return { config: {}, warnings: [] };

  const raw = await readFile(context.configPath, "utf8");
  const parsed = JSON.parse(raw) as PlanktonConfig;
  const warnings: string[] = [];

  if (parsed.tested_version === undefined && typeof parsed.cc_tested_version === "string") {
    parsed.tested_version = parsed.cc_tested_version;
    warnings.push("Using legacy cc_tested_version as tested_version.");
  }

  if (!isObject(parsed.subprocess)) parsed.subprocess = {};
  const coerced = coerceDelegate(parsed.subprocess.delegate_cmd, warnings);
  if (coerced) parsed.subprocess.delegate_cmd = coerced;
  if (!parsed.subprocess.settings_file) parsed.subprocess.settings_file = ".plankton/subprocess-settings.json";

  if (warnings.length > 0 && !warnedLegacyDelegate) {
    warnedLegacyDelegate = true;
    for (const warning of warnings) console.warn(`[plankton] ${warning}`);
  }

  return { config: parsed, warnings };
}

export async function readConfigForWrite(context: PlanktonContext): Promise<PlanktonConfig> {
  if (!context.configPath) throw new Error("No .plankton/config.json found for this project.");
  const raw = await readFile(context.configPath, "utf8");
  return JSON.parse(raw) as PlanktonConfig;
}

export async function writeConfig(context: PlanktonContext, config: PlanktonConfig): Promise<void> {
  if (!context.configPath) throw new Error("No .plankton/config.json found for this project.");
  await writeFile(context.configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
}

const simpleLanguageKeys = new Set(["python", "shell", "yaml", "json", "toml", "dockerfile", "markdown"]);
const structuredLanguageKeys = new Set(["typescript", "elixir"]);
const topLevelKeys = new Set([
  "hook_enabled",
  "languages",
  "protected_files",
  "security_linter_exclusions",
  "phases",
  "subprocess",
  "jscpd",
  "package_managers",
]);

function rejectUnsafeKey(key: string): void {
  if (!key || key.includes(".") || key === "__proto__" || key === "constructor" || key === "prototype") {
    throw new Error(`Invalid config key: ${key}`);
  }
}

function assertStringArray(value: unknown, key: string): asserts value is string[] {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`${key} must be an array of strings.`);
  }
}

export function setValidatedConfigValue(config: PlanktonConfig, key: string, value: unknown): void {
  rejectUnsafeKey(key);

  if (simpleLanguageKeys.has(key)) {
    if (typeof value !== "boolean") throw new Error(`${key} must be a boolean.`);
    config.languages = isObject(config.languages) ? config.languages : {};
    config.languages[key] = value;
    return;
  }

  if (structuredLanguageKeys.has(key)) {
    if (typeof value !== "boolean" && !isObject(value)) throw new Error(`${key} must be a boolean or object.`);
    config.languages = isObject(config.languages) ? config.languages : {};
    config.languages[key] = value;
    return;
  }

  if (!topLevelKeys.has(key)) throw new Error(`Config key '${key}' is not allowed.`);

  switch (key) {
    case "hook_enabled":
      if (typeof value !== "boolean") throw new Error("hook_enabled must be a boolean.");
      config.hook_enabled = value;
      return;
    case "protected_files":
    case "security_linter_exclusions":
      assertStringArray(value, key);
      config[key] = value;
      return;
    case "languages":
    case "phases":
    case "subprocess":
    case "jscpd":
    case "package_managers":
      if (!isObject(value)) throw new Error(`${key} must be an object.`);
      config[key] = value;
      return;
    default:
      throw new Error(`Config key '${key}' is not allowed.`);
  }
}

export function getEnabledLanguages(config: PlanktonConfig): string[] {
  const languages = isObject(config.languages) ? config.languages : {};
  return Object.entries(languages)
    .filter(([, value]) => {
      if (typeof value === "boolean") return value;
      if (isObject(value)) return value.enabled !== false;
      return false;
    })
    .map(([key]) => key)
    .sort();
}

export function formatConfigSummary(context: PlanktonContext, config: PlanktonConfig): string {
  const languages = getEnabledLanguages(config);
  const protectedCount = Array.isArray(config.protected_files) ? config.protected_files.length : 0;
  const packageManagers = isObject(config.package_managers) ? config.package_managers : {};
  const subprocess = isObject(config.subprocess) ? config.subprocess : {};

  return [
    "Plankton status",
    `Root: ${context.root}`,
    `Config: ${context.configPath ?? "not found (no-op)"}`,
    `Project hooks: ${context.projectHooksDir}`,
    `Bundled hooks: ${context.bundledHooksDir}`,
    `Enabled languages: ${languages.length > 0 ? languages.join(", ") : "none"}`,
    `Protected files: ${protectedCount}`,
    `Package managers: python=${String(packageManagers.python ?? "off")}, javascript=${String(packageManagers.javascript ?? "off")}`,
    `Delegate command: ${String(subprocess.delegate_cmd ?? "pi")}`,
  ].join("\n");
}
