#!/usr/bin/env bash
# bulk_idm_user_cleanup.sh
# Delete a specific set of FreeIPA/IdM users that were previously created.

set -euo pipefail

# -------------------- Defaults --------------------
FROM_CSV=""           # e.g. /root/new_idm_users_20250814-1010.csv
PREFIX=""             # e.g. u
START_INDEX=1
COUNT=0
PAD=4                 # zero-padding used when created (e.g. 0001)
DRY_RUN=0
YES=0                 # require explicit confirmation unless --yes

usage() {
  cat <<EOF
Usage: $0 [--from-csv FILE] | [--prefix STR --start-index N --count N] [options]

Exactly one of:
  --from-csv FILE        Delete usernames listed in the CSV the create-script wrote
                         (expects header with first column "username" or a column named "username").
  --prefix STR           Username prefix used when creating (e.g., "u" -> u0001..)
  --start-index N        Starting index used (e.g., 1)
  --count N              Number of users to remove (e.g., 1000)

Options:
  --pad N                Zero-padding width used for usernames (default: 4 -> u0001)
  --dry-run              Show what would be deleted, make no changes
  --yes                  Skip interactive confirmation
  -h, --help             Show this help

Examples:
  $0 --from-csv /root/new_idm_users_20250814-1010.csv
  $0 --prefix u --start-index 1 --count 1000 --pad 4
  $0 --prefix student --start-index 501 --count 1000 --yes
EOF
}

err() { echo >&2 "ERROR: $*"; }
info() { echo "INFO: $*"; }

# -------------------- Parse args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-csv) FROM_CSV="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --start-index) START_INDEX="${2:-}"; shift 2 ;;
    --count) COUNT="${2:-}"; shift 2 ;;
    --pad) PAD="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# -------------------- Pre-flight --------------------
command -v ipa >/dev/null 2>&1 || { err "'ipa' CLI not found. Install ipa-client (e.g., 'sudo dnf install ipa-client')"; exit 1; }
if ! klist -s 2>/dev/null; then
  err "No Kerberos ticket found. Run 'kinit admin' (or appropriate principal) and try again."
  exit 1
fi

# Build delete list
declare -a USERS=()

padn() { printf "%0${PAD}d" "$1"; }

if [[ -n "$FROM_CSV" ]]; then
  [[ -f "$FROM_CSV" ]] || { err "CSV not found: $FROM_CSV"; exit 1; }
  # Try to read a "username" column; otherwise assume first column is username
  # Accept commas or semicolons; ignore blank/comment lines
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    # Normalize separators to comma
    line="${line//;/,}"
    # Skip header if it contains 'username' (case-insensitive)
    if [[ "${line,,}" == username,* || "${line,,}" == *",username,"* || "${line,,}" == *",username" ]]; then
      continue
    fi
    IFS=',' read -r u _rest <<<"$line"
    # If the first field is empty but there's a "username" named column later, try to detect it
    if [[ -z "$u" && "${line,,}" == *"username"* ]]; then
      # find index of username column by header first; this is a best-effort fallback
      continue
    fi
    # Strip spaces/quotes
    u="${u//\"/}"
    u="${u// /}"
    [[ -n "$u" ]] && USERS+=("$u")
  done < "$FROM_CSV"
  [[ ${#USERS[@]} -gt 0 ]] || { err "No usernames parsed from CSV: $FROM_CSV"; exit 1; }
else
  # Pattern mode
  if [[ -z "$PREFIX" || "$COUNT" -le 0 ]]; then
    err "When not using --from-csv, you must specify --prefix, --start-index, and --count."
    usage; exit 1
  fi
  end=$((START_INDEX + COUNT - 1))
  for i in $(seq "$START_INDEX" "$end"); do
    USERS+=("${PREFIX}$(padn "$i")")
  done
fi

# De-duplicate (just in case)
mapfile -t USERS < <(printf "%s\n" "${USERS[@]}" | awk 'NF' | sort -u)

# Sanity preview
echo "The following ${#USERS[@]} usernames are targeted:"
printf '  %s\n' "${USERS[@]}"

# Extra safety check: verify each exists in IdM first
declare -a EXISTING=()
declare -a MISSING=()
for u in "${USERS[@]}"; do
  if ipa user-show "$u" >/dev/null 2>&1; then
    EXISTING+=("$u")
  else
    MISSING+=("$u")
  fi
done

echo
echo "Summary:"
echo "  Found in IdM: ${#EXISTING[@]}"
echo "  Not found   : ${#MISSING[@]}"
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  err "Nothing to delete (none of the specified users exist)."
  exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "[DRY-RUN] Would run deletions for the ${#EXISTING[@]} existing users above."
  exit 0
fi

if [[ $YES -ne 1 ]]; then
  echo
  read -r -p "Type 'DELETE ${#EXISTING[@]}' to confirm removal of these users: " confirm
  if [[ "$confirm" != "DELETE ${#EXISTING[@]}" ]]; then
    err "Confirmation failed. Aborting."
    exit 1
  fi
fi

# Deletion loop
FAILED=0
for u in "${EXISTING[@]}"; do
  if ipa user-del "$u" >/dev/null 2>&1; then
    echo "Deleted $u"
  else
    echo "FAILED to delete $u"
    FAILED=$((FAILED+1))
  fi
done

echo
if [[ $FAILED -eq 0 ]]; then
  echo "Done. All ${#EXISTING[@]} users deleted."
else
  echo "Done with errors. ${FAILED} deletions failed out of ${#EXISTING[@]}."
  echo "Check server logs or try again for those users."
fi
