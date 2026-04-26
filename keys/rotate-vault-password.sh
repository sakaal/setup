#!/usr/bin/env bash
#
# rotate-vault-password.sh — generate a new Ansible Vault password and
# store it in Proton Pass at pass://Setup Keys/vault_pass-<vault-id>/password.
#
# The vault-id encodes the scope and the year of password generation:
#   <scope>_<yy>     e.g. sam_setup_26  (year 2026)
#
# The password itself is 26 characters of Crockford base32 (130 bits of
# entropy).
#
# Idempotent: if the item already exists, its password field is updated.
# Safe: refuses to proceed if pass-cli isn't installed, isn't logged in,
# or if the Setup Keys vault doesn't exist.
#
# Manually triggered. Not part of the unattended bootstrap path.
#
# Usage:
#   ./rotate-vault-password.sh                    # default vault-id sam_setup_<current-year>
#   ./rotate-vault-password.sh --vault-id sam_setup_26
#   ./rotate-vault-password.sh --help

set -uo pipefail

VAULT="Setup Keys"
DEFAULT_VAULT_ID="sam_setup_$(date +%y)"
VAULT_ID="${DEFAULT_VAULT_ID}"

err() { printf '%s\n' "$*" >&2; }

# --- Args ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-id)
      VAULT_ID="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      err "Unknown argument: $1"
      err "Run with --help for usage."
      exit 1 ;;
  esac
done

ITEM="vault_pass-${VAULT_ID}"

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

# --- Generate the password ---
#
# 26 characters of Crockford base32 (alphabet 0-9 A-H J-K M-N P-T V-X Y-Z),
# 5 bits per character → 130 bits of entropy. No trailing whitespace.

NEW_PASS="$(python3 -c "
import os, sys
alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
sys.stdout.write(''.join(alphabet[b % 32] for b in os.urandom(26)))
")"

if [[ ${#NEW_PASS} -ne 26 ]]; then
  err "Generated password is not 26 characters — refusing to proceed."
  exit 1
fi

# --- Confirm before overwriting an existing item ---

if pass-cli item view --vault-name "${VAULT}" --item-title "${ITEM}" >/dev/null 2>&1; then
  printf 'Item %s/%s already exists. Replace its password? [y/N] ' "${VAULT}" "${ITEM}"
  read -r confirm
  [[ "${confirm}" == "y" ]] || { err "Aborted. No changes made."; exit 1; }
  echo "Updating existing item ${VAULT}/${ITEM}..."
  pass-cli item update \
    --vault-name "${VAULT}" \
    --item-title "${ITEM}" \
    --field "password=${NEW_PASS}"
else
  echo "Creating new item ${VAULT}/${ITEM}..."
  pass-cli item create login \
    --vault-name "${VAULT}" \
    --title "${ITEM}" \
    --username "ansible-vault" \
    --password "${NEW_PASS}"
fi

NEW_PASS=""

cat <<EOF

Stored at pass://${VAULT}/${ITEM}/password
Vault ID: ${VAULT_ID}

Reminder: if you have existing ansible-vault-encrypted files using a
previous vault password, you'll need to re-key them with the new password
before they decrypt. Add the new vault-id to your ansible.cfg's
vault_identity_list, then:

  ansible-vault rekey --encrypt-vault-id ${VAULT_ID} <encrypted-file>

Once all files are re-keyed, remove the old vault-id and password from
Pass and ansible.cfg.
EOF
