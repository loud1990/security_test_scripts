#!/usr/bin/env bash
# check_certs.sh
# Search /etc for .pem and .crt files, validate them as x509 certs, and show issuer/subject.
# If the issuer matches the subject, it indicates a self-signed cert.

find /etc -type f \( -name "*.pem" -o -name "*.crt" \) | while read -r f; do
    if openssl x509 -in "$f" -noout >/dev/null 2>&1; then
        echo "=== $f ==="
        openssl x509 -in "$f" -noout -issuer -subject
    fi
done