# Agent Instructions & Operating Rules

> **CRITICAL MANDATORY DIRECTIVE:**
> Every AI agent working on this repository MUST ALWAYS read the context files and `CLAUDE.md` in order BEFORE writing code, making architectural decisions, starting any work, or replying to the user in every session and turn.

## Context Files Prerequisite (MANDATORY)

Before implementing, making any architectural decision, starting any work, or replying to the user, ALWAYS read the context files and `CLAUDE.md` in order:

1. `CLAUDE.md` — entry-point context and guidelines
2. `CONTEXT/project-overview.md` (or `context/project-overview.md`) — product definition, goals, features, and scope
3. `CONTEXT/architecture.md` (or `context/architecture.md`) — system structure, boundaries, storage model, and invariants
4. `CONTEXT/ui-context.md` (or `context/ui-context.md`) — theme, colors, typography, and component conventions
5. `CONTEXT/code-standards.md` (or `context/code-standards.md`) — implementation rules and conventions
6. `CONTEXT/ai-workflow-rules.md` (or `context/ai-workflow-rules.md`) — development workflow, scoping rules, and delivery approach
7. `CONTEXT/progress-tracker.md` (or `context/progress-tracker.md`) — current phase, completed work, open questions, and next steps

### Rules & Workflow Invariants
- **Always read the context files first**: Read `CLAUDE.md` and all `CONTEXT/*.md` files before every action, reply, or implementation step.
- Update `CONTEXT/progress-tracker.md` after each meaningful implementation change.
- If implementation changes the architecture, scope, or standards documented in the context files, update the relevant file before continuing.
- No AI attribution in commits or PRs (no `Co-Authored-By` trailers).
- Do not run `dart format`.
- Never `git checkout` a file to discard changes; re-edit or stash.
- Verify `flutter analyze` passes with zero errors and zero warnings before committing.
