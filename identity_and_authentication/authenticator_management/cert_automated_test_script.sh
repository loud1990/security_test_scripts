#!/usr/bin/env bash
set -euo pipefail

# CCMS Certificate Compliance Auditor for RHEL 8.10
# Scans system certs, checks issuer against CCMS CA(s), verifies chains, and reports non-compliance.

# ---- User-configurable defaults ----
CCMS_DIR="${CCMS_DIR:-/root/ccms-trusted}"     # Put your CCMS Root + Intermediates here (PEM)
OUTPUT_DIR="${OUTPUT_DIR:-/root/ccms_audit}"
SCAN_PATHS_DEFAULT="/etc /usr/local /var"
EXTRA_SCAN_PATHS="${EXTRA_SCAN_PATHS:-}"        # e.g. "/opt /srv"
FIND_MAXDEPTH="${FIND_MAXDEPTH:-}"              # e.g. "-maxdepth 6" to limit
PARALLELISM="${PARALLELISM:-4}"                 # parallel openssl verifies
APACHE_CONF_DIR="/etc/httpd"
NGINX_CONF_DIR="/etc/nginx"
POSTFIX_MAIN_CF="/etc/postfix/main.cf"
DOVECOT_CONF_DIR="/etc/dovecot"
OPENLDAP_CLIENT_CONF="/etc/openldap/ldap.conf"
TRUST_STORE_DIR="/etc/pki/ca-trust"

mkdir -p "$OUTPUT_DIR"
REPORT_CSV="$OUTPUT_DIR/cert_inventory.csv"
NONCCMS_TXT="$OUTPUT_DIR/non_ccms_findings.txt"
SUMMARY_TXT="$OUTPUT_DIR/summary.txt"
CCMS_BUNDLE="$OUTPUT_DIR/ccms_bundle.pem"
ALLOW_ISSUERS_TXT="$OUTPUT_DIR/ccms_allow_issuers.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

red()   { printf "\033[1;31m%s\033[0m\n" "$*"; }
green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing dependency: $1"; exit 1; }
}

# ---- Pre-flight checks ----
need openssl
need grep
need awk
need sed
need find
need xargs
need date
need sort
need uniq
need tr
need paste
need column
need wc

if [ ! -d "$CCMS_DIR" ]; then
  red "CCMS_DIR not found: $CCMS_DIR"
  echo "Place your CCMS CA PEM files (root + intermediates) in $CCMS_DIR" >&2
  exit 1
fi

# Build CCMS bundle & issuer allowlist
> "$CCMS_BUNDLE"
> "$ALLOW_ISSUERS_TXT"
has_ccms_pem=0
while IFS= read -r -d '' pem; do
  has_ccms_pem=1
  cat "$pem" >> "$CCMS_BUNDLE"
  # Normalize issuer (RFC2253) for exact matching
  iss=$(openssl x509 -in "$pem" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer= //')
  # If file is a CA, its Subject may be issuer of issued leafs; add Subject as well
  sub=$(openssl x509 -in "$pem" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject= //')
  [ -n "$iss" ] && echo "$iss" >> "$ALLOW_ISSUERS_TXT"
  [ -n "$sub" ] && echo "$sub" >> "$ALLOW_ISSUERS_TXT"
done < <(find "$CCMS_DIR" -type f \( -iname '*.pem' -o -iname '*.crt' \) -print0)

if [ "$has_ccms_pem" -eq 0 ]; then
  red "No CCMS PEMs found under $CCMS_DIR. Add your CCMS CA certs and retry."
  exit 1
fi

# Deduplicate issuers
sort -u "$ALLOW_ISSUERS_TXT" -o "$ALLOW_ISSUERS_TXT"

# Header for CSV
echo "Path,Type,Subject,Issuer,NotBefore,NotAfter,Serial,SHA256,IssuerMatch,ChainVerified,Status" > "$REPORT_CSV"
> "$NONCCMS_TXT"
> "$SUMMARY_TXT"

# Utility: Determine if file contains an X.509 cert
is_x509() {
  local f="$1"
  openssl x509 -in "$f" -noout >/dev/null 2>&1
}

# Extract cert metadata
cert_field_block() {
  local f="$1"
  local subject issuer notbefore notafter serial sha256
  subject=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject= //')
  issuer=$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer= //')
  notbefore=$(openssl x509 -in "$f" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')
  notafter=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  serial=$(openssl x509 -in "$f" -noout -serial 2>/dev/null | sed 's/^serial=//')
  sha256=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/^SHA256 Fingerprint=//;s/://g')
  printf "%s|%s|%s|%s|%s|%s" "$subject" "$issuer" "$notbefore" "$notafter" "$serial" "$sha256"
}

issuer_matches_ccms() {
  local issuer="$1"
  grep -Fxq "$issuer" "$ALLOW_ISSUERS_TXT"
}

chain_verifies() {
  local f="$1"
  # -partial_chain allows chains that end at any cert in bundle (useful w/ intermediates)
  if openssl verify -CAfile "$CCMS_BUNDLE" -partial_chain -purpose sslserver "$f" >/dev/null 2>&1 \
     || openssl verify -CAfile "$CCMS_BUNDLE" -partial_chain -purpose any "$f" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

is_expired() {
  local notafter="$1"
  # Convert to seconds since epoch; openssl date is like "Jan  1 12:34:56 2025 GMT"
  local exp_ts cur_ts
  exp_ts=$(date -d "$notafter" +%s 2>/dev/null || echo 0)
  cur_ts=$(date +%s)
  if [ "$exp_ts" -ne 0 ] && [ "$exp_ts" -lt "$cur_ts" ]; then
    return 0
  fi
  return 1
}

csv_escape() {
  # Escape double-quotes and wrap with quotes (safe for commas/newlines)
  echo "\"$(echo -n "$1" | sed 's/"/""/g')\""
}

append_csv_row() {
  local path="$1" type="$2" subject="$3" issuer="$4" nb="$5" na="$6" serial="$7" sha="$8" imatch="$9" cverify="${10}" status="${11}"
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$(csv_escape "$path")" "$(csv_escape "$type")" "$(csv_escape "$subject")" "$(csv_escape "$issuer")" \
    "$(csv_escape "$nb")" "$(csv_escape "$na")" "$(csv_escape "$serial")" "$(csv_escape "$sha")" \
    "$(csv_escape "$imatch")" "$(csv_escape "$cverify")" "$(csv_escape "$status")" \
    >> "$REPORT_CSV"
}

queue_cert() {
  # Write file path into queue to parallelize processing
  echo "$1" >> "$TMP_DIR/queue.txt"
}

process_one() {
  local f="$1"
  local type="generic"
  local subject issuer nb na serial sha imatch cverify status

  IFS="|" read -r subject issuer nb na serial sha < <(cert_field_block "$f")

  if [ -z "$issuer" ] && [ -z "$subject" ]; then
    # Not a valid leaf or parse error; skip quietly
    return 0
  fi

  if issuer_matches_ccms "$issuer"; then
    imatch="YES"
  else
    imatch="NO"
  fi

  if chain_verifies "$f"; then
    cverify="YES"
  else
    cverify="NO"
  fi

  status="OK"
  if [ "$imatch" != "YES" ]; then
    status="NON-CCMS"
  fi
  if is_expired "$na"; then
    if [ "$status" = "OK" ]; then status="EXPIRED"; else status="${status}+EXPIRED"; fi
  fi
  if [ "$cverify" != "YES" ]; then
    if [ "$status" = "OK" ]; then status="UNVERIFIED"; else status="${status}+UNVERIFIED"; fi
  fi

  append_csv_row "$f" "$type" "$subject" "$issuer" "$nb" "$na" "$serial" "$sha" "$imatch" "$cverify" "$status"

  if [[ "$status" != "OK" ]]; then
    {
      echo "==== $f ===="
      echo "Subject : $subject"
      echo "Issuer  : $issuer"
      echo "Expires : $na"
      echo "SHA256  : $sha"
      echo "Status  : $status"
      echo
    } >> "$NONCCMS_TXT"
  fi
}

# ---- Discover certs: generic scan ----
yellow "Building certificate inventory…"
> "$TMP_DIR/queue.txt"

SCAN_ROOTS="$SCAN_PATHS_DEFAULT"
[ -n "$EXTRA_SCAN_PATHS" ] && SCAN_ROOTS="$SCAN_ROOTS $EXTRA_SCAN_PATHS"

# Find files that *look* like PEM/CRT, then filter by openssl x509 parser.
# Also include common service-configured paths discovered later.
while IFS= read -r -d '' file; do
  if is_x509 "$file"; then
    queue_cert "$file"
  fi
done < <(find $SCAN_ROOTS $FIND_MAXDEPTH -type f \( -iname '*.crt' -o -iname '*.pem' \) -print0 2>/dev/null)

# ---- Helper: extract cert paths from configs ----
extract_paths_from_files() {
  local pattern="$1"; shift
  local files=("$@")
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    grep -E "$pattern" "$f" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /\//) print $i}' \
      | sed 's/;.*$//' | sed 's/"//g' | sed "s/'//g"
  done | sort -u
}

# Apache
if [ -d "$APACHE_CONF_DIR" ]; then
  mapfile -t apache_confs < <(grep -rilE 'SSLCertificate(File|ChainFile|KeyFile)' "$APACHE_CONF_DIR" 2>/dev/null || true)
  if [ "${#apache_confs[@]}" -gt 0 ]; then
    yellow "Inspecting Apache TLS cert references…"
    while IFS= read -r cpath; do
      [ -f "$cpath" ] || continue
      if is_x509 "$cpath"; then queue_cert "$cpath"; fi
    done < <(extract_paths_from_files 'SSL(Certificate(File|ChainFile|KeyFile))' "${apache_confs[@]}")
  fi
fi

# NGINX
if [ -d "$NGINX_CONF_DIR" ]; then
  mapfile -t nginx_confs < <(grep -rilE 'ssl_certificate|ssl_client_certificate' "$NGINX_CONF_DIR" 2>/dev/null || true)
  if [ "${#nginx_confs[@]}" -gt 0 ]; then
    yellow "Inspecting NGINX TLS cert references…"
    while IFS= read -r cpath; do
      [ -f "$cpath" ] || continue
      if is_x509 "$cpath"; then queue_cert "$cpath"; fi
    done < <(extract_paths_from_files 'ssl_(certificate|client_certificate)' "${nginx_confs[@]}")
  fi
fi

# Postfix
if [ -f "$POSTFIX_MAIN_CF" ]; then
  yellow "Inspecting Postfix TLS cert references…"
  while IFS= read -r cpath; do
    [ -f "$cpath" ] || continue
    if is_x509 "$cpath"; then queue_cert "$cpath"; fi
  done < <(extract_paths_from_files '^(smtpd_tls_cert_file|smtp_tls_cert_file|smtpd_tls_CAfile|smtp_tls_CAfile)' "$POSTFIX_MAIN_CF")
fi

# Dovecot
if [ -d "$DOVECOT_CONF_DIR" ]; then
  mapfile -t dovecot_confs < <(grep -rilE 'ssl_cert|ssl_client_ca_file' "$DOVECOT_CONF_DIR" 2>/dev/null || true)
  if [ "${#dovecot_confs[@]}" -gt 0 ]; then
    yellow "Inspecting Dovecot TLS cert references…"
    while IFS= read -r cpath; do
      [ -f "$cpath" ] || continue
      if is_x509 "$cpath"; then queue_cert "$cpath"; fi
    done < <(extract_paths_from_files 'ssl_(cert|client_ca_file)' "${dovecot_confs[@]}")
  fi
fi

# OpenLDAP client TLS
if [ -f "$OPENLDAP_CLIENT_CONF" ]; then
  yellow "Inspecting OpenLDAP client TLS references…"
  while IFS= read -r cpath; do
    [ -f "$cpath" ] || continue
    if is_x509 "$cpath"; then queue_cert "$cpath"; fi
  done < <(grep -Ei 'TLS_CERT|TLS_CACERT|TLS_CACERTDIR' "$OPENLDAP_CLIENT_CONF" 2>/dev/null \
           | awk '{print $2}' | sed 's/"//g' | sed "s/'//g")
fi

# Certmonger (if present)
if command -v getcert >/dev/null 2>&1; then
  yellow "Inspecting certmonger tracked certs…"
  getcert list 2>/dev/null | awk -F': ' '/certificate:/ {print $2}' | while read -r p; do
    [ -f "$p" ] || continue
    if is_x509 "$p"; then queue_cert "$p"; fi
  done
fi

# Deduplicate queue
sort -u "$TMP_DIR/queue.txt" -o "$TMP_DIR/queue.txt"

# ---- Process certs in parallel ----
yellow "Verifying $(wc -l < "$TMP_DIR/queue.txt") certificate file(s) against CCMS…"
# xargs -P for parallel processing
cat "$TMP_DIR/queue.txt" | xargs -I{} -P "$PARALLELISM" bash -c 'process_one "$@"' _ {}

# ---- Trust store inspection ----
yellow "Checking system trust store for non‑CCMS anchors…"
NONCCMS_ANCHORS=0
while IFS= read -r -d '' anchor; do
  if is_x509 "$anchor"; then
    iss=$(openssl x509 -in "$anchor" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject= //')
    if ! issuer_matches_ccms "$iss"; then
      NONCCMS_ANCHORS=$((NONCCMS_ANCHORS+1))
      {
        echo "Anchor: $anchor"
        echo "Subject: $iss"
        echo
      } >> "$NONCCMS_TXT"
    fi
  fi
done < <(find "$TRUST_STORE_DIR/source/anchors" -type f -print0 2>/dev/null || true)

# ---- Summary ----
TOTAL=$(($(wc -l < "$REPORT_CSV") - 1))
NONOK=$(awk -F',' 'NR>1 { if ($11 !~ /^"OK"$/) c++ } END{print c+0}' "$REPORT_CSV")
EXPIRED=$(awk -F',' 'NR>1 { if ($11 ~ /EXPIRED/) e++ } END{print e+0}' "$REPORT_CSV")
UNVERIFIED=$(awk -F',' 'NR>1 { if ($11 ~ /UNVERIFIED/) v++ } END{print v+0}' "$REPORT_CSV")
NONCCMS=$(awk -F',' 'NR>1 { if ($11 ~ /NON-CCMS/) n++ } END{print n+0}' "$REPORT_CSV")

{
  echo "Total cert files checked: $TOTAL"
  echo "Non-OK statuses       : $NONOK"
  echo "  - NON-CCMS          : $NONCCMS"
  echo "  - EXPIRED           : $EXPIRED"
  echo "  - UNVERIFIED chain  : $UNVERIFIED"
  echo "Non-CCMS trust anchors: $NONCCMS_ANCHORS"
  echo
  echo "CSV report : $REPORT_CSV"
  echo "Findings   : $NONCCMS_TXT"
  echo "CCMS bundle: $CCMS_BUNDLE"
  echo "Allowlist  : $ALLOW_ISSUERS_TXT"
} | tee "$SUMMARY_TXT"

if [ "$NONOK" -gt 0 ] || [ "$NONCCMS_ANCHORS" -gt 0 ]; then
  red   "Non‑compliance detected. See $NONCCMS_TXT and $REPORT_CSV"
else
  green "All checked certificates appear compliant with CCMS issuers and chain verification."
fi

exit 0
