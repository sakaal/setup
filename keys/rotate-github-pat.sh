#!/usr/bin/env bash
#
# rotate-github-pat.sh — open the browser to mint a new GitHub Personal Access
# Token, then store it in Proton Pass at pass://Setup Keys/github-pat/password.
#
# Idempotent: when the item already exists (rotation), only the
# password is updated; the username is preserved from what's in Pass.
# When the item does not exist yet (first-time creation), the username
# is derived from the new PAT via GET https://api.github.com/user.
# Safe: refuses to proceed if pass-cli isn't installed, isn't logged
# in, or if the Setup Keys vault doesn't exist.
#
# Manually triggered. Not part of the unattended bootstrap path.

set -euo pipefail

VAULT="Setup Keys"
ITEM="github-pat"
SCOPES="repo"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
DESCRIPTION_RAW="Setup Keys/github-pat (${HOSTNAME_SHORT})"
DESCRIPTION_ENC="$(printf '%s' "${DESCRIPTION_RAW}" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
PAT_URL="https://github.com/settings/tokens/new?scopes=${SCOPES}&description=${DESCRIPTION_ENC}"

err() { printf '%s\n' "$*" >&2; }

# --- Args ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      err "Unknown argument: $1"
      err "Run with --help for usage."
      exit 1 ;;
  esac
done

# --- Pre-flight ---

command -v pass-cli >/dev/null 2>&1 || {
  err "pass-cli not installed."
  err "Install with: brew install protonpass/tap/pass-cli"
  exit 1
}

if ! pass-cli vault list --output json >/dev/null 2>&1; then
  err "pass-cli is not logged in (or session expired)."
  err "Run: pass-cli login"
  exit 1
fi

VAULTS_JSON="$(pass-cli vault list --output json)"
if ! printf '%s' "${VAULTS_JSON}" \
    | python3 -c "import json,sys; sys.exit(0 if any(v.get('name')=='${VAULT}' for v in json.load(sys.stdin)['vaults']) else 1)"; then
  err "Vault '${VAULT}' not found in your Proton Pass account."
  err "Create it via the Proton Pass app, or:"
  err "  pass-cli vault create --name \"${VAULT}\""
  exit 1
fi

# --- Open browser to GitHub PAT creation page ---

echo "Opening GitHub Personal Access Token creation page..."
echo "URL: ${PAT_URL}"
if command -v open >/dev/null 2>&1; then
  open "${PAT_URL}"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${PAT_URL}"
else
  echo "(open the URL manually in your browser)"
fi

# --- Read the new PAT (hidden input) ---

echo
printf 'Paste the new PAT, then press Enter (input hidden): '
IFS= read -rs PAT
echo

if [ -z "${PAT}" ]; then
  err "Empty input. Aborted."
  exit 1
fi

case "$PAT" in
  ghp_*|github_pat_*) ;;
  *) err "Warning: PAT does not match expected GitHub prefix (ghp_ or github_pat_); proceeding anyway." ;;
esac

# --- Write to Proton Pass ---

if pass-cli item view --vault-name "${VAULT}" --item-title "${ITEM}" >/dev/null 2>&1; then
  # Rotation: item already in Pass — only password changes; username preserved.
  echo "Updating existing item ${VAULT}/${ITEM} (password only; username preserved)..."
  pass-cli item update \
    --vault-name "${VAULT}" \
    --item-title "${ITEM}" \
    --field "password=${PAT}"
else
  # First-time creation: derive username from the new PAT.
  GH_USERNAME="$(curl -fsSL -H "Authorization: token ${PAT}" https://api.github.com/user 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",""))' 2>/dev/null)"
  if [[ -z "${GH_USERNAME}" ]]; then
    err "Could not derive GitHub login from the new PAT (token invalid or /user not accessible)."
    exit 1
  fi
  echo "Creating new item ${VAULT}/${ITEM} (username=${GH_USERNAME})..."
  pass-cli item create login \
    --vault-name "${VAULT}" \
    --title "${ITEM}" \
    --username "${GH_USERNAME}" \
    --password "${PAT}"
fi

PAT=""

cat <<EOF

Stored at pass://${VAULT}/${ITEM}/password

Reminder: revoke any older GitHub PATs you no longer need:
  https://github.com/settings/tokens
EOF
