find_all_certs.sh - Documentation

Overview
This script searches /etc for certificate files with .pem or .crt extensions, validates them as X.509 certificates using OpenSSL, and prints the issuer and subject for each valid certificate found. If the issuer matches the subject, the certificate is self-signed (as noted in the script header).

Prerequisites
- OpenSSL must be installed and available in PATH.
- The script reads files under /etc; ensure you have the necessary permissions.

Inputs
- No command-line options are supported. Run the script as-is.

Usage
- Run the script:

```bash
./identity_and_authentication/authenticator_management/find_all_certs.sh
```

Output
- For each valid certificate file, the script prints:
  === /path/to/cert.pem ===
  issuer= /C=US/O=Example/OU=Org/CN=example.com
  subject= /C=US/O=Example/OU=Org/CN=example.com
- If a certificate is self-signed, issuer and subject will be identical in the printed lines.
- Non-certificate PEM/CRT files or unreadable files are ignored quietly or may produce OpenSSL warnings.

Notes
- The script prints only files that OpenSSL recognizes as valid X.509 certificates.
- Time and system locale can affect the exact text format of issuer/subject strings.

Security considerations
- Scanning /etc can reveal sensitive information; avoid logging or exposing this data publicly.
- Run with restricted permissions and handle the output securely.

Examples
- Sample output (formatted):

```text
=== /etc/ssl/certs/ca-certificates.crt ===
issuer= /C=US/O=The GoDaddy Class 2 Certification Authority/OU=.../CN=Entrust.net
subject= /C=US/O=The GoDaddy Class 2 Certification Authority/OU=.../CN=Entrust.net
```

See also
- [`find_all_certs.sh`](identity_and_authentication/authenticator_management/find_all_certs.sh)
- [`bulk_idm_user_create.sh.md`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh.md)