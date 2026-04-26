# Frequently Asked Questions

## Won't future models make this unnecessary?

Models will improve. But there will always be a gap between what a model
*can* do and what *your project requires*. Style is opinionated.
Architecture is opinionated. Every team has conventions that no amount
of general training covers. As models get smarter, the enforcement
shifts from catching basic errors to enforcing team-specific
architectural constraints and separation-of-concerns rules that
prompting alone can't reliably handle. Plankton is designed to be
re-evaluated step by step. If a layer becomes unnecessary, remove it.
No bloat carried forward.

## How is this different from pre-commit hooks?

Pre-commit hooks catch errors *after* you try to commit. You see the
errors, copy-paste them to the agent, the agent fixes them, you commit
again, more errors appear, creating an infinite loop that burns context and
wastes turns. Plankton enforces quality *at write-time*: the moment the
agent writes a file, violations are caught and fixed by dedicated
Pi instances before
the agent even continues. The loop never reaches the commit
stage. Think of it as the live linting that IDEs provided before agentic
coding. Errors corrected in real-time so you never wait for the commit.

## Isn't this just running a linter?

Running a linter gives you a list of errors. Plankton is a three-phase
enforcement system: it auto-formats first (fixing 40-50% of issues
silently), collects remaining violations as structured data, then
passes remaining violations to Pi instances that analyze each
violation and generate precise fixes. It routes violations to different
model tiers based on complexity: fast, lightweight models for simple
formatting and capable models for architectural refactoring, right-sizing
intelligence
so tokens aren't wasted. It protects its own configuration from tampering. It
enforces package manager choices. It's a full quality pipeline.

## Won't the agent just modify the linting rules?

This is one of the most underappreciated risks in agentic coding. LLMs
will happily exhibit rule-gaming behavior: instead of fixing actual code
issues, they modify your linting configuration to make violations
disappear. Without structural protection, agents working autonomously
will quietly edit your `.ruff.toml`, `biome.json`, `.shellcheckrc`, or
pre-commit configs to loosen rules, and the violations vanish without
the code ever improving. Plankton prevents this through multiple defense
layers: real-time blocking of config edits before they happen
(PreToolUse hooks reject modifications to all linter config files),
session-end detection that catches any changes that slipped through and
offers git-based restoration, and a policy layer that enforces "fix
your code" as a structural
constraint. Most discussions about
LLM-ready codebases and complexity enforcement remain vague. Plankton
is a concrete, working implementation of the protection system that
agentic coding actually needs.

## Why not just use Pi's LSP plugins?

Pi's LSP plugins (Pyright, typescript-language-server, etc.)
give the agent awareness of type errors and syntax issues after every
edit. This is valuable, but it's fundamentally different from what
Plankton does.

LSP diagnostics are **advisory**: Pi sees the errors and *decides*
whether to fix them. It can judge a diagnostic as irrelevant and move
on. Plankton hooks are **structural**: they run outside the model's
decision loop, catch violations deterministically, and delegate fixes
to dedicated Pi instances before the agent continues. The model cannot bypass
them.

LSP also covers only what language servers report: type errors,
missing imports, syntax issues. It does not enforce style rules
(formatting, naming, docstring conventions, import ordering),
complexity limits, security scanning (Semgrep, bandit), dead code
detection, Dockerfile best practices, YAML strictness, or config file
protection. Plankton enforces all of these.

The two systems are complementary. LSP provides real-time type
awareness during editing. Plankton provides deterministic, multi-linter
enforcement that cannot be bypassed. Use both.

## Why Pi?

Pi is the only LLM coding tool with hooks this extended,
granular, and customizable. Its hook system exposes three event types:
PreToolUse (before an action), PostToolUse (after an action),
Stop (at session end), all at the individual tool-call level. This means
Plankton can intercept every single file write, run linters, delegate
fixes to Pi instances, and verify results before the agent
proceeds. No other agentic coding tool exposes event-level hooks with
this depth: tool-specific matchers, JSON input/output schemas, exit
code semantics, and the ability to block, allow, or modify operations
programmatically. Plankton exists because Pi's hook
architecture makes it possible.

## Does this slow down the agent?

The system is built for speed. All linters are Rust-based (Ruff, Biome,
ShellCheck via compiled binaries) to stay within tight latency budgets.
Auto-formatting runs in under 100ms for most files. The Pi fix
instance is synchronous (the main agent waits), but the trade-off is
deliberate: 25 seconds of intelligent fixing saves minutes of manual
error correction,
context loss, and pre-commit loops. In practice, the main agent barely
notices the process happening.

## What makes the linter choice so important?

Everything Plankton does depends on linters that are fast enough to run
on every edit and granular enough to enforce whatever your team cares
about. Ruff formats 250,000 lines of Python in under a tenth of a
second, 32x faster than the previous generation. Biome handles
TypeScript at similar speeds. These are compiled Rust tools that finish
before the agent notices they ran.

Speed alone would be useless without granularity. These linters expose
hundreds of individually configurable rules: quote style, import
ordering, cyclomatic complexity thresholds, Pydantic field validation,
Dockerfile label requirements, async anti-patterns, dead code detection,
security scanning patterns. Plankton's config.json gives you surgical
control over all of it. Enable or disable languages individually, choose
which rules block the agent versus which stay advisory, set session
thresholds for heavier tools like duplicate detection, route specific
violation types to different model tiers. The enforcement is only as
good as the rules underneath it, and the current generation of linters
makes those rules both fast enough for write-time execution and specific
enough to encode whatever your team considers important.

## Don't the fix instances trigger more hooks?

No. The dedicated Pi instances run with all hooks disabled. They
edit the file, but no linting hooks fire during their edits. This
eliminates recursion entirely. After the fix instance exits, the parent
hook re-runs all linters to verify the result, so no violations are
masked. The entire system is also synchronous: one file, one fix
instance, one verification pass. No parallel processes competing for
the same file.

## What happens when fix instances can't resolve a violation?

Most of the time, nothing visible happens. The dedicated Pi
instances fix all violations silently, and the main agent continues
without knowing the process occurred. When violations remain (which
is rare), the system escalates: the hook communicates structured
feedback to the main agent with what's still broken, giving it
actionable context to attempt the fix itself. Internally, the fix
instances receive violations as structured JSON with precise line
numbers, column positions, and violation codes. This is what makes
their fixes so targeted. And when escalation does happen, the same
structured information reaches the main agent, creating a two-tier
problem-solving system: dedicated instances handle what they can,
complex issues return to the full agent with the context it needs.

## Can I use this on an existing codebase?

Plankton works best when adopted from the start of a project. Enabling
it on a large existing codebase will surface every pre-existing
violation in every file the agent touches, which can mean hundreds of
violations triggering refactoring cascades. This is by design (the Boy
Scout Rule: edit a file, own all its violations), but it can be
overwhelming. For existing codebases, either customize `config.json`
extensively to start with a narrow rule set and widen it gradually, or
adopt Plankton on new modules first and expand coverage over time.
