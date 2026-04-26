import { Text } from "@mariozechner/pi-tui";

export function renderLintCall(args: any, theme: any, context: any): Text {
  const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
  const path = typeof args?.path === "string" ? args.path : "unknown";
  text.setText(`${theme.fg("toolTitle", theme.bold("plankton_lint"))} ${theme.fg("muted", path)}`);
  return text;
}

export function renderLintResult(result: any, options: any, theme: any, _context: any): Text {
  if (options?.isPartial) return new Text(theme.fg("warning", "Plankton lint running..."), 0, 0);

  const details = result?.details ?? {};
  const summary = typeof details.summary === "string" ? details.summary : "Plankton lint completed.";
  const clean = Boolean(details.clean);
  const color = clean ? "success" : "warning";
  const prefix = clean ? "clean" : "attention";
  return new Text(theme.fg(color, `Plankton ${prefix}: `) + theme.fg("muted", summary), 0, 0);
}
