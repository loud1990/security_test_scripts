# cert_automated_test_script.sh.md - Documentation

## Overview
This script is the CCMS Certificate Compliance Auditor for RHEL 8.10. It scans system certificate locations, collects candidate PEM/CRT files, validates them with OpenSSL, and reports on issuer/subject alignment against a CCMS issuer allowlist. It also checks certificate validity chains and expiration, producing a CSV report and a summary of findings.

## Prerequisites
- OpenSSL must be installed and available in PATH.
- The script reads certificate files from the CCMS_DIR and system trust sources; ensure you have read access to these paths.
- Standard shell utilities used by the script (grep, awk, sed, find, xargs, date, sort, uniq, tr, paste, column, wc).

## Environment inputs (overridable via environment variables)
- CCMS_DIR: Root path containing CCMS CA PEMs (default: /root/ccms-trusted)
- OUTPUT_DIR: Output directory for reports (default: /root/ccms_audit)
- SCAN_PATHS_DEFAULT: Initial scan roots (default: "/etc /usr/local /var")
- EXTRA_SCAN_PATHS: Additional scan roots (default: empty)
- FIND_MAXDEPTH: Find command max depth (default: empty)
- PARALLELISM: Degree of parallelism for certificate verification (default: 4)
- APACHE_CONF_DIR: Apache config directory (default: /etc/httpd)
- NGINX_CONF_DIR: Nginx config directory (default: /etc/nginx)
- POSTFIX_MAIN_CF: Postfix main.cf path (default: /etc/postfix/main.cf)
- DOVECOT_CONF_DIR: Dovecot config directory (default: /etc/dovecot)
- OPENLDAP_CLIENT_CONF: OpenLDAP client config path (default: /etc/openldap/ldap.conf)
- TRUST_STORE_DIR: System trust store directory (default: /etc/pki/ca-trust)

## Outputs
- REPORT_CSV: CSV report of all scanned certificates (default: ${OUTPUT_DIR}/cert_inventory.csv)
- NONCCMS_TXT: Findings that are non-CCMS (default: ${OUTPUT_DIR}/non_ccms_findings.txt)
- SUMMARY_TXT: Summary of the scan (default: ${OUTPUT_DIR}/summary.txt)
- CCMS_BUNDLE: Concatenated CCMS CA bundle used for validation (default: ${OUTPUT_DIR}/ccms_bundle.pem)
- ALLOW_ISSUERS_TXT: Deduplicated allowlist of issuers (default: ${OUTPUT_DIR}/ccms_allow_issuers.txt)
- TMP_DIR: Temporary working directory (auto-generated)
- The script prints key statuses to stdout and writes detailed results to the CSV and text reports.

## Usage
- Run with defaults:
  ./identity_and_authentication/authenticator_management/cert_automated_test_script.sh

- Override defaults via environment variables:
  CCMS_DIR=/path/to/ccms OUTPUT_DIR=/path/to/out ./identity_and_authentication/authenticator_management/cert_automated_test_script.sh
  Example: scan additional paths and run at lower depth
  EXTRA_SCAN_PATHS="/opt /srv" FIND_MAXDEPTH="-maxdepth 6" PARALLELISM=6 ./identity_and_authentication/authenticator_management/cert_automated_test_script.sh

## Typical command flow inside the script (high level)
- Validate dependencies (openssl, grep, awk, sed, find, xargs, date, sort, uniq, tr, paste, column, wc)
- Build a CCMS bundle by concatenating all PEM/CRT files in CCMS_DIR and derive issuer/subject allowlist
- Prepare CSV and findings files
- Discover certificates from system paths and common configuration references (Apache, Nginx, Postfix, Dovecot, OpenLDAP, Certmonger)
- For each discovered certificate:
  - Extract subject, issuer, notBefore, notAfter, serial, SHA256
  - Determine if issuer is in the CCMS allowlist
  - Verify the certificate chain against the CCMS bundle
  - Mark status as OK, NON-CCMS, EXPIRED, UNVERIFIED, etc.
  - Append a row to the CSV with all fields (escaped for CSV)
  - Write non-OK findings to NONCCMS_TXT
- Summarize results in SUMMARY_TXT and print a final status line:
  - If any non-OK statuses or non-CCMS anchors exist, print a red warning with references to details
  - Otherwise print a green success line

## Outputs explained (CSV columns)
- Path: certificate path
- Type: certificate type (generic)
- Subject: certificate subject
- Issuer: certificate issuer
- NotBefore: notBefore date
- NotAfter: notAfter date
- Serial: certificate serial
- SHA256: certificate SHA-256 fingerprint
- IssuerMatch: YES if issuer is in CCMS allowlist, else NO
- ChainVerified: YES if certificate chain verified against CCMS bundle, else NO
- Status: overall status (OK, NON-CCMS, EXPIRED, UNVERIFIED, etc.)

## Security considerations
- The script reads sensitive certificate data; restrict access to output reports and the CCMS bundle.
- Ensure the OUTPUT_DIR and CCMS_DIR permissions are tightened; consider backups and secure deletion for temporary data.

## See also
- [`bulk_idm_user_create.sh`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh)
- [`find_all_certs.sh`](identity_and_authentication/authenticator_management/find_all_certs.sh)
- [`cert_automated_test_script.sh`](identity_and_authentication/authenticator_management/cert_automated_test_script.sh)

## Cross-references
- This documentation complements the existing docs for related scripts:
- [`bulk_idm_user_create.sh`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh)
- [`find_all_certs.sh`](identity_and_authentication/authenticator_management/find_all_certs.sh)
- The current script reference: identity_and_authentication/authenticator_management/cert_automated_test_script.sh

## Notes
- This doc is intended to be a concise guide for operators. For exact on-disk behavior and all internal edge cases, consult the script source at identity_and_authentication/authenticator_management/cert_automated_test_script.sh.