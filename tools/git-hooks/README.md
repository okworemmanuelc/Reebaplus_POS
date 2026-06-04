# Git hooks — secret / sensitive-file guard

These hooks stop secrets and sensitive files from being committed or pushed to the
(private) repo. They are plain POSIX shell — **nothing to install**.

## One-time activation (per clone)

Git does not auto-enable hooks on clone, so run this once after cloning on any
machine:

```sh
git config core.hooksPath tools/git-hooks
chmod +x tools/git-hooks/pre-commit tools/git-hooks/pre-push
```

Verify with: `git config core.hooksPath` → should print `tools/git-hooks`.

## What gets blocked

**Sensitive filenames** (even with `git add -f`): `.env*`, `.envrc`, `*.jks`,
`*.keystore`, `key.properties`, `*.pem`, `*.p12`, `*.p8`, `*.pfx`,
`google-services.json`, `GoogleService-Info.plist`, `service-account*.json`, `id_rsa*`.

**Secret content pasted into any tracked file** (scanned in the staged diff):
- private-key blocks (`-----BEGIN ... PRIVATE KEY-----`)
- AWS access key ids (`AKIA…`)
- Supabase **service-role** keys (JWT whose decoded payload says `service_role`)

It intentionally does **not** flag the Supabase **anon** key in `lib/main.dart`:
anon keys are client-public by design (they ship in every APK and are gated by
row-level security), so blocking them would be a permanent false positive.

- `pre-commit` runs on `git commit` and scans the staged changes.
- `pre-push` runs on `git push` and re-scans the commits being pushed (backstop for
  anything committed with `--no-verify`).

## Escape hatch

If you are certain a flagged item is safe:

```sh
git commit --no-verify     # skip pre-commit
git push   --no-verify     # skip pre-push
```

## Note

This is a local guard. It is not enforced on GitHub's servers (server-side push
protection requires GitHub's paid Secret Protection add-on, which isn't available
on personal private repos). Keep `core.hooksPath` set on every machine you commit
from.
