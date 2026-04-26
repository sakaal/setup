#!/usr/bin/env bash
#
# adopt-ssh-keys.sh — copy SSH keys from ~/.ssh/ to Proton Pass.
#
# Scans ~/.ssh/ (only — not elsewhere) for SSH key files matching the
# naming policy and imports any that aren't yet in Pass "Setup Keys".
# Existing items in Pass are left alone (mismatches are reported, not
# replaced).
#
# Naming policy:  id_<algo>_<user>@<machine>_<iso8601-datetime>
#   <iso8601-datetime> may be:
#     - year + month:     2019-04, 201904
#     - date only:        2019-04-01, 20190401
#     - date + time:      2019-04-01T14:30, 20190401T1430
#     - second precision: 2019-04-01T14:30:00, 20190401T143000, 20140819T054009Z
#     - underscore separator: 2019-04-01_14:30 (T or _ both accepted)
#     - optional trailing Z (UTC indicator): 2014-08-19T054009Z
#
# Examples that match:
#   id_rsa_alice@hostA_2024-01
#   id_rsa_alice@workstation_2024-06-30
#   id_ed25519_alice@laptop_20240412T1430
#   id_ecdsa_alice@server_2014-08-19T054009Z
#
# For each matching private key file:
#   - Validate it's an unencrypted SSH private key
#   - Compare against any item in Pass with the same title
#   - Match → skip silently
#   - Mismatch → report; do NOT replace the Pass item
#   - Not present in Pass → propose for adoption
# Files in ~/.ssh/ starting with `id_` but not matching the policy are
# reported separately so you can rename them or address them manually.
# After surveying, prompt once before importing the unadopted set.
#
# Usage:
#   ./adopt-ssh-keys.sh                       Scan and prompt
#   ./adopt-ssh-keys.sh --exclude PATTERN     Skip filenames containing PATTERN
#                                             (substring match; flag may repeat)
#   ./adopt-ssh-keys.sh --help                Show this help
#
# Manually triggered. Not part of the unattended bootstrap path.

set -uo pipefail

VAULT="Setup Keys"
SSH_DIR="${HOME}/.ssh"

usage() {
  sed -n '3,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^set -uo/d'
}

err()  { printf '%s\n' "$*" >&2; }
info() { printf '  \xe2\x86\x92 %s\n' "$*"; }
ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  \xe2\x9c\x97 %s\n' "$*" >&2; exit 1; }

# --- Flag parsing ---

EXCLUDES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude)
      [[ $# -ge 2 ]] || fail "--exclude requires an argument"
      EXCLUDES+=("$2"); shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
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
  fail "Vault '${VAULT}' not found in your Proton Pass account."
fi

# --- Scan ~/.ssh/ for candidates and stragglers ---

# Two streams from one python pass:
#   "MATCH\t<full path>"     — filename matches policy and not excluded
#   "STRAGGLER\t<filename>"  — starts with id_ but doesn't match policy
#   "EXCLUDED\t<filename>"   — matches policy but excluded by flag
SCAN_OUTPUT="$(SSH_DIR="${SSH_DIR}" \
               EXCLUDES="$(IFS=$'\n'; printf '%s' "${EXCLUDES[*]:-}")" \
               python3 -c '
import os, re, sys
ssh = os.environ["SSH_DIR"]
excl = [p for p in os.environ.get("EXCLUDES", "").split("\n") if p]

dt = r"\d{4}-?\d{2}(?:-?\d{2}(?:[T_]\d{2}:?\d{2}(?::?\d{2})?[Zz]?)?)?"
rx = re.compile(rf"^id_[a-z][a-z0-9]*_[a-zA-Z][\w-]*@[\w.-]+_{dt}$")

for name in sorted(os.listdir(ssh)):
    full = os.path.join(ssh, name)
    if not os.path.isfile(full) or os.path.islink(full):
        continue
    if name.endswith(".pub"):
        continue
    if rx.match(name):
        if any(p in name for p in excl):
            print(f"EXCLUDED\t{name}")
        else:
            print(f"MATCH\t{full}")
    elif name.startswith("id_"):
        print(f"STRAGGLER\t{name}")
')"

CANDIDATES=()
STRAGGLERS=()
EXCLUDED_BY_FLAG=()
while IFS=$'\t' read -r kind value; do
  [[ -z "${kind}" ]] && continue
  case "${kind}" in
    MATCH)     CANDIDATES+=("${value}") ;;
    STRAGGLER) STRAGGLERS+=("${value}") ;;
    EXCLUDED)  EXCLUDED_BY_FLAG+=("${value}") ;;
  esac
done <<< "${SCAN_OUTPUT}"

# Surface stragglers and excluded items up-front
if [[ ${#STRAGGLERS[@]} -gt 0 ]]; then
  warn "Files in ${SSH_DIR} starting with 'id_' but NOT matching the naming policy (skipped):"
  printf '    %s\n' "${STRAGGLERS[@]}" >&2
  echo "  Rename them to the policy or address manually if they should be in Pass." >&2
fi

if [[ ${#EXCLUDED_BY_FLAG[@]} -gt 0 ]]; then
  info "Excluded by --exclude flags:"
  printf '    %s\n' "${EXCLUDED_BY_FLAG[@]}"
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  info "No SSH key files matching the naming policy found in ${SSH_DIR}"
  exit 0
fi

info "Found ${#CANDIDATES[@]} key file(s) matching the naming policy."

# --- Snapshot existing Pass items ---

PASS_SNAPSHOT="$(pass-cli item list "${VAULT}" --output json)"

# Get Pass's public_key (algo + base64 portion only) for a given title.
# Returns empty if no matching active item.
pass_pub_for() {
  PASS_SNAPSHOT="${PASS_SNAPSHOT}" python3 -c '
import json, os, sys
d = json.loads(os.environ["PASS_SNAPSHOT"])
title = sys.argv[1]
for i in d.get("items", []):
    if i.get("state") != "Active":
        continue
    if i["content"]["title"] == title:
        c = i["content"]["content"]
        if "SshKey" in c:
            pub = c["SshKey"].get("public_key", "")
            parts = pub.strip().split(None, 2)
            print(" ".join(parts[:2]))
            break
' "$1"
}

# Get Pass's note field for a given title (returns empty if missing or item not found).
pass_note_for() {
  PASS_SNAPSHOT="${PASS_SNAPSHOT}" python3 -c '
import json, os, sys
d = json.loads(os.environ["PASS_SNAPSHOT"])
title = sys.argv[1]
for i in d.get("items", []):
    if i.get("state") != "Active":
        continue
    if i["content"]["title"] == title:
        print(i["content"].get("note", ""))
        break
' "$1"
}

# Strip a public key down to algo + base64 (drop comment).
normalize_pub() {
  printf '%s' "$1" | python3 -c '
import sys
parts = sys.stdin.read().strip().split(None, 2)
print(" ".join(parts[:2]))
'
}

# --- Categorize ---

TO_ADOPT=()
ALREADY=()
MISMATCH=()
ENCRYPTED=()

for path in "${CANDIDATES[@]}"; do
  title="$(basename "${path}")"

  if ! local_pub_raw="$(ssh-keygen -y -P '' -f "${path}" 2>/dev/null)"; then
    ENCRYPTED+=("${title}")
    continue
  fi
  local_pub="$(normalize_pub "${local_pub_raw}")"

  pass_pub="$(pass_pub_for "${title}")"

  if [[ -z "${pass_pub}" ]]; then
    TO_ADOPT+=("${path}")
  elif [[ "${pass_pub}" == "${local_pub}" ]]; then
    ALREADY+=("${title}")
  else
    MISMATCH+=("${title}")
  fi
done

# --- Report ---

echo
if [[ ${#ALREADY[@]} -gt 0 ]]; then
  info "Already in Pass (matches local — no action):"
  printf '    %s\n' "${ALREADY[@]}"
fi

if [[ ${#ENCRYPTED[@]} -gt 0 ]]; then
  warn "Skipped (passphrase-protected or not a valid private key):"
  printf '    %s\n' "${ENCRYPTED[@]}" >&2
  echo "  Import these manually with:" >&2
  echo "    pass-cli item create ssh-key import --vault-name \"${VAULT}\" \\" >&2
  echo "      --title <filename> --from-private-key <path> --password" >&2
fi

if [[ ${#MISMATCH[@]} -gt 0 ]]; then
  warn "Mismatch (Pass item exists with same title but different public key — refusing to replace):"
  printf '    %s\n' "${MISMATCH[@]}" >&2
  echo "  Investigate before resolving. Either delete the Pass item and re-run," >&2
  echo "  or rename the local file to a non-conflicting title." >&2
fi

# Back-fill the searchable note on items already in Pass that predate
# the convention. Runs regardless of whether new keys are being adopted,
# so re-running this script also reconciles older items.
NOTE_TEXT="SSH key pair"

set_note_if_empty() {
  local title="$1"
  local current_note
  current_note="$(pass_note_for "${title}")"
  if [[ -n "${current_note}" ]]; then
    return 1   # leave existing note alone (safe-idempotent)
  fi
  pass-cli item update \
    --vault-name "${VAULT}" \
    --item-title "${title}" \
    --field "note=${NOTE_TEXT}" >/dev/null 2>&1
}

if [[ ${#ALREADY[@]} -gt 0 ]]; then
  for title in "${ALREADY[@]}"; do
    if set_note_if_empty "${title}"; then
      info "Back-filled note on ${title}"
    fi
  done
fi

if [[ ${#TO_ADOPT[@]} -eq 0 ]]; then
  echo
  ok "Nothing new to adopt."
  exit 0
fi

echo
info "Will adopt ${#TO_ADOPT[@]} key(s) into pass://${VAULT}:"
for p in "${TO_ADOPT[@]}"; do
  echo "    $(basename "${p}")"
done

echo
printf 'Proceed with import? [y/N] '
read -r confirm
[[ "${confirm}" == "y" ]] || { err "Aborted. No changes made."; exit 1; }

# --- Adopt ---

# Extract the comment (text after the second whitespace-delimited token) from
# a public-key file, or empty string if no .pub or no comment.
extract_comment() {
  local pub="$1"
  [[ -f "$pub" ]] || { printf ''; return; }
  python3 -c '
import sys
parts = open(sys.argv[1]).read().strip().split(None, 2)
print(parts[2] if len(parts) >= 3 else "")
' "$pub"
}

ADOPT_FAILED=()
for path in "${TO_ADOPT[@]}"; do
  title="$(basename "${path}")"
  info "Importing ${title}..."
  if pass-cli item create ssh-key import \
      --vault-name "${VAULT}" \
      --title "${title}" \
      --from-private-key "${path}" >/dev/null 2>&1; then
    ok "Adopted ${title}"
    # Add the SSH key comment as a glance-able extra field, if present.
    # Capital "Comment" because Pass UI shows custom-field names verbatim
    # (no auto-capitalization), and Pass stores casing as-set on first
    # creation — so we have to set the right casing up-front.
    comment="$(extract_comment "${path}.pub")"
    if [[ -n "${comment}" ]]; then
      if pass-cli item update \
          --vault-name "${VAULT}" \
          --item-title "${title}" \
          --field "Comment=${comment}" >/dev/null 2>&1; then
        info "  Added Comment field: ${comment}"
      else
        warn "  Imported but failed to add Comment field for ${title}"
      fi
    fi
    # Set searchable note (item is freshly created, so always empty)
    if pass-cli item update \
        --vault-name "${VAULT}" \
        --item-title "${title}" \
        --field "note=${NOTE_TEXT}" >/dev/null 2>&1; then
      info "  Set note: ${NOTE_TEXT}"
    fi
  else
    warn "Failed to import ${title}"
    ADOPT_FAILED+=("${title}")
  fi
done


echo
if [[ ${#ADOPT_FAILED[@]} -gt 0 ]]; then
  err "Some imports failed:"
  printf '    %s\n' "${ADOPT_FAILED[@]}" >&2
  exit 1
fi

ok "All eligible keys adopted into pass://${VAULT}"
