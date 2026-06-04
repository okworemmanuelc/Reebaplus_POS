#!/bin/sh
# Shared secret-scanning logic for the pre-commit and pre-push hooks.
# Sourced by both hooks. POSIX sh; only needs git, grep, tr, cut, base64.
#
# It deliberately flags ONLY high-signal secrets so it never false-positives on
# the Supabase *anon* key that legitimately ships in lib/main.dart (anon keys are
# client-public by design). It targets: sensitive filenames, private-key blocks,
# AWS access keys, and Supabase *service-role* keys (the dangerous ones).

# Filenames that must never be committed (extended-regex, matched on the path).
SECRET_FILENAME_RE='(^|/)\.env(\.[^/]+)?$|(^|/)\.envrc$|\.jks$|\.keystore$|(^|/)key\.properties$|\.pem$|\.p12$|\.p8$|\.pfx$|(^|/)google-services\.json$|GoogleService-Info\.plist$|service-account[^/]*\.json$|(^|/)id_rsa'

# Best-effort base64url decode (JWT payload segment). Prints decoded bytes or
# nothing. Tries GNU (-d) then BSD/macOS (-D).
_b64url_decode() {
  s=$(printf '%s' "$1" | tr '_-' '/+')
  case $(( ${#s} % 4 )) in
    2) s="${s}==" ;;
    3) s="${s}=" ;;
  esac
  printf '%s' "$s" | base64 -d 2>/dev/null || printf '%s' "$s" | base64 -D 2>/dev/null || true
}

# secret_scan <newline-separated-file-list> <unified-diff-text>
# Prints any violations to stdout. Returns 0 when clean, 1 when something is found.
secret_scan() {
  _files=$1
  _diff=$2
  _bad=0

  # --- 1. Filename blocklist (also catches `git add -f`) ------------------
  if [ -n "$_files" ]; then
    _hits=$(printf '%s\n' "$_files" | grep -E "$SECRET_FILENAME_RE" || true)
    if [ -n "$_hits" ]; then
      printf '%s\n' "$_hits" | while IFS= read -r f; do
        [ -n "$f" ] && printf '  x sensitive filename: %s\n' "$f"
      done
      _bad=1
    fi
  fi

  # --- 2. Content scan of ADDED lines only -------------------------------
  _added=$(printf '%s\n' "$_diff" | grep -E '^\+' | grep -Ev '^\+\+\+' || true)
  if [ -n "$_added" ]; then
    # 2a. Private key blocks
    if printf '%s\n' "$_added" | grep -Eq -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'; then
      printf '  x private key block (-----BEGIN ... PRIVATE KEY-----)\n'
      _bad=1
    fi
    # 2b. AWS access key id
    if printf '%s\n' "$_added" | grep -Eq 'AKIA[0-9A-Z]{16}'; then
      printf '  x AWS access key id (AKIA...)\n'
      _bad=1
    fi
    # 2c. Supabase service-role JWT: decode payload, look for service_role
    _jwts=$(printf '%s\n' "$_added" | grep -oE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' || true)
    if [ -n "$_jwts" ]; then
      _sr=$(printf '%s\n' "$_jwts" | while IFS= read -r jwt; do
        [ -n "$jwt" ] || continue
        if _b64url_decode "$(printf '%s' "$jwt" | cut -d. -f2)" | grep -q 'service_role'; then
          echo HIT
        fi
      done)
      if [ -n "$_sr" ]; then
        printf '  x Supabase SERVICE-ROLE key (decoded JWT role=service_role)\n'
        _bad=1
      fi
    fi
    # 2d. Cheap fallback: a line naming service_role alongside a JWT
    if printf '%s\n' "$_added" | grep -Eiq 'service_role.*eyJ[A-Za-z0-9_-]{10,}\.'; then
      printf '  x service-role key (service_role label + JWT)\n'
      _bad=1
    fi
  fi

  return $_bad
}
