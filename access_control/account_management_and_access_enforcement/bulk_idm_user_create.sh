#!/usr/bin/env bash
# bulk_idm_user_create.sh
# Create many FreeIPA/IdM users with random passwords and save to a CSV.

set -euo pipefail

# -------------------- Defaults (override via flags) --------------------
COUNT=3            # how many users to create
START_INDEX=1         # starting number (1 -> u0001)
PREFIX="u"            # username prefix (u0001, u0002, ...)
FIRSTNAME_PREFIX="Test"
LASTNAME_PREFIX="User"
EMAIL_DOMAIN=""       # if non-empty, sets email like user@domain
DEFAULT_SHELL="/bin/bash"
GROUP=""              # optional: existing IdM group to add each user to
DRY_RUN=0             # set to 1 for dry-run (no changes)

# -------------------- Helpers --------------------
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -c, --count N            Number of users to create (default: ${COUNT})
  -s, --start-index N      Starting index (default: ${START_INDEX})
  -p, --prefix STR         Username prefix (default: ${PREFIX})
  -f, --firstname STR      Firstname prefix (default: ${FIRSTNAME_PREFIX})
  -l, --lastname STR       Lastname prefix (default: ${LASTNAME_PREFIX})
  -d, --email-domain STR   Email domain to set (e.g. example.com)
  -S, --shell PATH         Login shell (default: ${DEFAULT_SHELL})
  -g, --group NAME         Add each user to this existing IdM group
  -n, --dry-run            Show actions without creating users
  -h, --help               Show this help

Examples:
  $0 --count 1000 --prefix u --group interns --email-domain example.com
  $0 -c 250 -s 501 -p student -g "Students"
EOF
}

err() { echo >&2 "ERROR: $*"; }
info() { echo "INFO: $*"; }

# -------------------- Parse args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--count) COUNT="${2:-}"; shift 2 ;;
    -s|--start-index) START_INDEX="${2:-}"; shift 2 ;;
    -p|--prefix) PREFIX="${2:-}"; shift 2 ;;
    -f|--firstname) FIRSTNAME_PREFIX="${2:-}"; shift 2 ;;
    -l|--lastname) LASTNAME_PREFIX="${2:-}"; shift 2 ;;
    -d|--email-domain) EMAIL_DOMAIN="${2:-}"; shift 2 ;;
    -S|--shell) DEFAULT_SHELL="${2:-}"; shift 2 ;;
    -g|--group) GROUP="${2:-}"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# -------------------- Pre-flight checks --------------------
command -v ipa >/dev/null 2>&1 || { err "'ipa' CLI not found. Install ipa-client (e.g., 'sudo dnf install ipa-client')"; exit 1; }

# Check kerberos ticket
if ! klist -s 2>/dev/null; then
  err "No Kerberos ticket found. Run 'kinit admin' (or appropriate principal) and try again."
  exit 1
fi

# Output file for credentials
TS="$(date +%Y%m%d-%H%M%S)"
OUT_CSV="/root/new_idm_users_${TS}.csv"
if [[ ${DRY_RUN} -eq 0 ]]; then
  touch "${OUT_CSV}"
  chmod 600 "${OUT_CSV}"
  echo "username,first,last,email,password" >> "${OUT_CSV}"
fi

# Verify group exists if specified
if [[ -n "${GROUP}" ]]; then
  if [[ ${DRY_RUN} -eq 0 ]]; then
    if ! ipa group-show "${GROUP}" >/dev/null 2>&1; then
      err "Group '${GROUP}' not found in IdM."
      exit 1
    fi
  else
    info "[DRY-RUN] Would verify group '${GROUP}' exists"
  fi
fi

pad4() {
  # zero-pad to 4 digits (e.g., 1 -> 0001). Adjust to pad5 if you’ll exceed 9999.
  printf "%04d" "$1"
}

# -------------------- Creation loop --------------------
END_INDEX=$((START_INDEX + COUNT - 1))
info "Creating users ${PREFIX}$(pad4 ${START_INDEX}) through ${PREFIX}$(pad4 ${END_INDEX})"
[[ ${DRY_RUN} -eq 0 ]] && info "Credentials will be saved to ${OUT_CSV}"

for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
  IDX=$(pad4 "${i}")
  USER="${PREFIX}${IDX}"
  GIVEN="${FIRSTNAME_PREFIX}${IDX}"
  SUR="${LASTNAME_PREFIX}"
  EMAIL=""
  [[ -n "${EMAIL_DOMAIN}" ]] && EMAIL="${USER}@${EMAIL_DOMAIN}"

  # Skip if already exists
  if ipa user-show "${USER}" >/dev/null 2>&1; then
    info "User ${USER} already exists. Skipping."
    continue
  fi

  CMD=(ipa user-add "${USER}"
       --first "${GIVEN}"
       --last "${SUR}"
       --shell "${DEFAULT_SHELL}"
       --random)

  [[ -n "${EMAIL}" ]] && CMD+=(--email "${EMAIL}")

  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "[DRY-RUN] Would run: ${CMD[*]}"
    [[ -n "${GROUP}" ]] && info "[DRY-RUN] Would add ${USER} to group ${GROUP}"
    continue
  fi

  # Create user and capture the random password from output
  OUTPUT="$("${CMD[@]}" 2>&1 || true)"
  if ! grep -qiE 'Added user|Random password' <<<"${OUTPUT}"; then
    err "Failed to create ${USER}. ipa output:"
    echo "${OUTPUT}"
    continue
  fi

  PASS="$(echo "${OUTPUT}" | awk -F': ' 'BEGIN{IGNORECASE=1} /Random password/{print $2; exit}')"
  if [[ -z "${PASS}" ]]; then
    err "Could not parse random password for ${USER}. ipa output:"
    echo "${OUTPUT}"
    continue
  fi

  # Optionally add to group
  if [[ -n "${GROUP}" ]]; then
    if ! ipa group-add-member "${GROUP}" --users="${USER}" >/dev/null 2>&1; then
      err "Created ${USER}, but failed to add to group ${GROUP}"
    fi
  fi

  # Save to CSV
  echo "${USER},${GIVEN},${SUR},${EMAIL},${PASS}" >> "${OUT_CSV}"
  echo "Created ${USER}"
done

if [[ ${DRY_RUN} -eq 0 ]]; then
  echo
  echo "Done. Credentials saved to: ${OUT_CSV}"
  echo "Set restrictive permissions and handle this file securely. Consider forcing password change at next login:"
  echo "  ipa pwpolicy-mod --minlife=0  # (if policy blocks immediate change)"
  echo "  # Or for each user: ipa user-mod <user> --setattr 'krbLastPwdChange=19700101000000Z' (advanced)"
fi
