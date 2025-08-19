#!/bin/bash
# ipa-ca-test.sh - Functional CA validation for Red Hat IdM / IPA (RHEL 8)
# Runs: create test service -> issue cert -> verify -> revoke -> confirm in CRL
# Requires: ipa, openssl, curl. Run with IPA admin creds (kinit admin).
# make it executable and run the following in terminal:
# sudo tee /usr/local/sbin/ipa-ca-test.sh >/dev/null <<'EOF'

set -euo pipefail

# --- Config (override via env) ---
TEST_LABEL="${TEST_LABEL:-ipa-ca-test}"
DOMAIN="${DOMAIN:-$(hostname -d 2>/dev/null || true)}"
REALM="${REALM:-$(awk -F' = ' '/default_realm/{print $2}' /etc/krb5.conf 2>/dev/null)}"
KEEP="${KEEP:-0}"          # set KEEP=1 to keep the temp files & service
IPA_HOST="${IPA_HOST:-$(hostname -f 2>/dev/null || true)}"
CAFILE="${CAFILE:-/etc/ipa/ca.crt}"

# --- Derived ---
if [[ -z "${DOMAIN:-}" ]]; then
  echo "ERROR: Could not determine system domain (hostname -d)." >&2
  exit 2
fi
if [[ -z "${REALM:-}" ]]; then
  echo "ERROR: Could not determine Kerberos REALM from /etc/krb5.conf." >&2
  exit 2
fi

TEST_FQDN="${TEST_LABEL}.${DOMAIN}"
SERVICE="HTTP/${TEST_FQDN}"
TMPDIR="$(mktemp -d)"
KEY="${TMPDIR}/test.key"
CSR="${TMPDIR}/test.csr"
CERT="${TMPDIR}/test.pem"
CRL="${TMPDIR}/crl.der"
CRL_TXT="${TMPDIR}/crl.txt"

PASS=true
CREATED_SERVICE=0

log() { printf '%s %s\n' "[*]" "$*"; }
ok()  { printf '%s %s\n' "[OK]" "$*"; }
fail(){ printf '%s %s\n' "[!!]" "$*" >&2; PASS=false; }
die(){  fail "$*"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# --- Preflight ---
need ipa
need openssl
need curl
[[ -r "$CAFILE" ]] || die "CA file not found/readable: $CAFILE"

log "=== IPA CA Functional Test ==="
log "Realm: ${REALM}"
log "Domain: ${DOMAIN}"
log "IPA host: ${IPA_HOST}"
log "Test service: ${SERVICE}@${REALM}"
echo

# --- 1) Create test service principal ---
log "[1] Creating test service principal..."
if ipa service-show "$SERVICE" >/dev/null 2>&1; then
  log "Service already exists, reusing: $SERVICE"
else
  if ipa service-add "$SERVICE" >/dev/null; then
    CREATED_SERVICE=1
    ok "Service added."
  else
    die "Failed to add service principal."
  fi
fi

# --- 2) Generate CSR ---
log "[2] Generating key and CSR..."
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$KEY" -out "$CSR" \
  -subj "/CN=${TEST_FQDN}" \
  -addext "subjectAltName=DNS:${TEST_FQDN}" >/dev/null 2>&1 \
  && ok "CSR generated." || die "Failed to generate CSR."

# --- 3) Request cert from IPA ---
log "[3] Requesting certificate from IPA..."
if ipa cert-request "$CSR" \
    --principal="${SERVICE}@${REALM}" \
    --certificate-out="$CERT" >/dev/null; then
  ok "Certificate issued and saved to ${CERT}."
else
  die "Cert request failed (check privileges and profile policy)."
fi

# --- 4) Verify issued certificate against IPA CA ---
log "[4] Verifying certificate..."
if openssl verify -CAfile "$CAFILE" "$CERT" >/dev/null 2>&1; then
  ok "Trust verification: OK"
else
  openssl verify -CAfile "$CAFILE" "$CERT" || true
  fail "Trust verification failed."
fi

log "Certificate summary:"
openssl x509 -in "$CERT" -noout -subject -issuer -dates -ext keyUsage -ext extendedKeyUsage 2>/dev/null | sed 's/^/  /'
echo

# --- Extract serials (hex & decimal) ---
HEX_SERIAL="$(openssl x509 -in "$CERT" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')"
# Get decimal via ipa (more reliable for ipa cert-revoke/show)
DEC_SERIAL="$(ipa cert-find --subject "CN=${TEST_FQDN}" --pkey-only 2>/dev/null | awk '/Serial number/{print $3}' | tail -1)"

[[ -n "$HEX_SERIAL" ]] || die "Could not parse hex serial from cert."
[[ -n "$DEC_SERIAL" ]] || die "Could not find decimal serial via ipa."

log "[4b] Serial (hex): ${HEX_SERIAL}"
log "[4c] Serial (dec): ${DEC_SERIAL}"

# --- 5) Revoke certificate & confirm status ---
log "[5] Revoking certificate (reason: key-compromise)..."
if ipa cert-revoke "$DEC_SERIAL" --revocation-reason=key-compromise >/dev/null; then
  ok "Revocation requested."
else
  fail "Revocation failed for serial ${DEC_SERIAL}."
fi

sleep 2
if ipa cert-show "$DEC_SERIAL" 2>/dev/null | grep -qi "REVOKED"; then
  ok "IPA now shows status: REVOKED"
else
  fail "IPA does not show REVOKED status yet."
fi

# --- 6) Determine CRL URL and verify revocation appears in CRL ---
log "[6] Checking CRL distribution point..."
CRL_URL="$(openssl x509 -in "$CERT" -noout -text | awk '/CRL Distribution Points/{f=1;next}/^[[:alnum:]]/{f=0}f' | sed -n 's/.*URI:\(.*\)/\1/p' | head -1)"
if [[ -z "${CRL_URL:-}" ]]; then
  # Fallback (common default)
  CRL_URL="http://${IPA_HOST}/ipa/crl/MasterCRL.bin"
  log "No CRL DP in cert; using fallback: ${CRL_URL}"
else
  log "CRL URL: ${CRL_URL}"
fi

log "Fetching CRL..."
if curl -fsSL "$CRL_URL" -o "$CRL"; then
  ok "CRL fetched."
else
  fail "Failed to fetch CRL from ${CRL_URL}."
fi

log "Parsing CRL..."
if openssl crl -inform der -in "$CRL" -noout -text > "$CRL_TXT" 2>/dev/null; then
  ok "CRL parsed."
else
  fail "Failed to parse CRL."
fi

# Check Next Update freshness
NEXT_UPDATE="$(awk '/Next Update/{print $0;exit}' "$CRL_TXT" | sed 's/^/  /')"
THIS_UPDATE="$(awk '/Last Update/{print $0;exit}' "$CRL_TXT" | sed 's/^/  /')"
log "CRL timings:"
echo "${THIS_UPDATE:-  (not found)}"
echo "${NEXT_UPDATE:-  (not found)}"

# In the CRL text, revoked cert serials are shown in hex (without 0x), typically uppercase
if grep -q "Serial Number: ${HEX_SERIAL}" "$CRL_TXT"; then
  ok "Revoked serial ${HEX_SERIAL} is present in the CRL."
else
  fail "Revoked serial ${HEX_SERIAL} NOT found in the CRL (may require more time depending on CRL schedule)."
fi

# --- 7) Optional: OCSP probe if AIA contains OCSP URL ---
OCSP_URL="$(openssl x509 -in "$CERT" -noout -ocsp_uri 2>/dev/null || true)"
if [[ -n "${OCSP_URL:-}" ]]; then
  log "[7] OCSP URL detected: $OCSP_URL"
  # Attempt OCSP query (non-fatal)
  if openssl ocsp -issuer "$CAFILE" -cert "$CERT" -url "$OCSP_URL" -no_nonce -resp_text -timeout 5 >/dev/null 2>&1; then
    ok "OCSP responder reachable."
  else
    fail "OCSP query failed (if you don't use OCSP, ignore this)."
  fi
else
  log "[7] No OCSP URL advertised in AIA; skipping OCSP probe."
fi

# --- 8) Summary ---
echo
log "=== SUMMARY ==="
$PASS && ok "Overall: PASS" || fail "Overall: FAIL"

# --- Cleanup ---
if [[ "$KEEP" -eq 1 ]]; then
  log "KEEP=1 set; leaving artifacts in: $TMPDIR"
else
  rm -rf "$TMPDIR"
fi

if [[ "$CREATED_SERVICE" -eq 1 && "$KEEP" -eq 0 ]]; then
  log "Deleting test service principal..."
  if ipa service-del "$SERVICE" >/dev/null; then
    ok "Service deleted."
  else
    fail "Failed to delete test service (manual cleanup may be needed): $SERVICE"
  fi
fi

exit $($PASS && echo 0 || echo 1)
EOF
sudo chmod +x /usr/local/sbin/ipa-ca-test.sh

# run it
sudo ipa-ca-test.sh