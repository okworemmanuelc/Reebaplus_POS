# AI Workflow Rules

These are direct instructions to the AI coding agent building Reebaplus POS. They are rules, not suggestions. Follow every one. When a rule here conflicts with your own judgement, this file wins. When a rule here conflicts with `architecture.md`, stop and surface the conflict — do not resolve it yourself.

## Approach

Build this project incrementally using a spec-driven workflow. The context files define what to build, how to build it, and the current state of progress. Implement against these specs only. Do not infer, invent, or improvise behaviour that is not written in a context file.

The context files are listed below in priority order. When files conflict, the higher file in this list wins. Surface any conflict rather than resolving it yourself.

```
context/
├── project-overview.md      # What the product does, goals, user flow, scope
├── architecture.md          # Stack, folder boundaries, storage model, sync model, invariants
├── code-standards.md        # Naming, types, widget rules, tokens, import order, module boundaries
├── ai-workflow-rules.md     # How to behave while building — this file
├── ui-context.md            # Design tokens, component library, visual conventions
└── progress-tracker.md      # Current unit, completed work, open questions
```

`CLAUDE.md` lives at the repository root (one level above `context/`). It is the entry-point instruction file Claude Code reads on every session. It points to this context folder and sets the session-level behaviour. Do not modify `CLAUDE.md` unless explicitly instructed.

Read every context file relevant to the current unit before writing any code. Re-read `architecture.md`'s Invariants section before every unit without exception. If you have not read these files in the current session, read them first. `progress-tracker.md` does not exist yet — create it before starting the first unit.

## Scoping Rules

- Work on one feature unit at a time. A unit is one screen, one repository, one DAO, one provider, one Edge Function, or one sync subsystem — not several at once.
- Prefer small, verifiable increments over large speculative changes. If you cannot describe what you are about to build in one sentence, the unit is too big.
- Do not combine unrelated system boundaries in a single implementation step. The UI layer, the repository layer, the local database layer, the remote layer, and the sync isolate are separate boundaries. Touching more than one in a single step requires splitting (see below).
- Do not build ahead of the spec. Do not add a field, a screen, or a capability because it "will probably be needed." If it is not in a context file, it is out of scope for this unit.
- Do not refactor code unrelated to the current unit. If you spot a problem elsewhere, log it in `progress-tracker.md` and keep moving.

## When to Split Work

Split an implementation step into smaller steps if it combines any of the following:

- UI changes (a widget or screen) and sync isolate changes (`lib/sync/`) in the same step.
- A repository change and an Edge Function change in the same step — the client and server boundaries are implemented and verified separately.
- More than one feature folder under `lib/features/`.
- A Drift schema change (a new table or migration) and the feature logic that consumes it — land the migration first, verify it, then build on it.
- Behaviour that is not clearly defined in the context files (resolve the definition first — see Handling Missing Requirements).

If a change cannot be verified end to end quickly, the scope is too broad — split it.

## Handling Missing Requirements

- Do not invent product behaviour that is not defined in the context files. An empty space in the spec is not permission to design; it is a blocker.
- If a requirement is ambiguous, resolve it in the relevant context file before implementing. Update `project-overview.md`, `architecture.md`, or `code-standards.md` with the clarified decision, then implement against the updated file.
- If a requirement is missing entirely, add it as an open question in `progress-tracker.md` before continuing. Write the question specifically: name the unit, name the undefined behaviour, and propose the options you see. Do not implement past the open question until it is answered.
- If two context files disagree, stop. Do not pick one. Log the contradiction in `progress-tracker.md` and surface it.
- Never silence an ambiguity by choosing the easier path. Surfacing a blocker is correct behaviour, not a failure.

## Protected Files

Do not modify the following unless explicitly instructed in the current task:

- `*.g.dart`, `*.freezed.dart`, and any other generated files. Regenerate them with `dart run build_runner build`; never hand-edit them.
- `lib/l10n/` generated output (the typed accessors). Edit the `.arb` source files instead, then regenerate.
- `architecture.md`'s Invariants section. The invariants are not yours to change. If a unit cannot be built without violating one, stop and surface it; do not edit the invariant to make your code legal.
- Any third-party package internals under the pub cache.
- The Drift database version and existing migrations. Add a new migration; never rewrite a shipped one.
- `analysis_options.yaml` linter rules. If a rule blocks you, fix the code, do not loosen the rule.

## Keeping Docs in Sync

Update the relevant context file in the same step whenever implementation changes any of the following. The doc update is part of the unit, not a follow-up.

- System architecture or folder boundaries → `architecture.md`.
- Storage model decisions (what lives in Drift, secure storage, or Supabase-only) → `architecture.md`.
- A new invariant, or a change to how an existing one is enforced → `architecture.md`.
- Code conventions, naming, or a new styling token → `code-standards.md`.
- Feature scope, the user flow, or a scope boundary moving in or out → `project-overview.md`.
- Visual or design decisions (tokens, component patterns, layout conventions) → `ui-context.md`.
- Any completed work, any new open question → `progress-tracker.md`.

A unit is not done while a context file still describes the old behaviour. Stale docs are a defect.

## Before Moving to the Next Unit

Do not start the next unit until all of the following are true. Verify each one explicitly; do not assume.

1. The current unit works end to end within its defined scope.
2. No invariant defined in `architecture.md` was violated. Re-read the Invariants section and confirm each relevant one by name.
3. The code follows `code-standards.md`: StatelessWidget-only, no `dynamic`, tokens not raw values, correct import order and module boundaries, append-only ledgers, all cloud writes through the outbox.
4. `progress-tracker.md` reflects the completed work and any open questions raised during the unit.
5. All context files touched by this unit are updated in the same step.
6. `flutter analyze` passes with zero errors and zero new warnings.
7. `flutter test` passes.
8. Generated code, if any schema or model changed, was regenerated with `dart run build_runner build` and committed.
