# Agent Instructions & Operating Rules

## Context Files Prerequisite (MANDATORY)

Before implementing, making any architectural decision, starting any work, or replying to the user, ALWAYS read the context files and `CLAUDE.md` in order:

1. `CLAUDE.md` — entry-point context and guidelines
2. `context/project-overview.md` — product definition, goals, features, and scope
3. `context/architecture.md` — system structure, boundaries, storage model, and invariants
4. `context/ui-context.md` — theme, colors, typography, and component conventions
5. `context/code-standards.md` — implementation rules and conventions
6. `context/ai-workflow-rules.md` — development workflow, scoping rules, and delivery approach
7. `context/progress-tracker.md` — current phase, completed work, open questions, and next steps

### Rules & Workflow Invariants
- Update `context/progress-tracker.md` after each meaningful implementation change.
- If implementation changes the architecture, scope, or standards documented in the context files, update the relevant file before continuing.
- No AI attribution in commits or PRs (no `Co-Authored-By` trailers).
- Do not run `dart format`.
- Never `git checkout` a file to discard changes; re-edit or stash.
- Verify `flutter analyze` passes with zero errors and zero warnings before committing.
