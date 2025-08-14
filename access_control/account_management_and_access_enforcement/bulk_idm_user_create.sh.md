[`bulk_idm_user_create.sh.md`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh.md:1)
# bulk_idm_user_create.sh - Documentation

## Overview
This script creates many FreeIPA/IdM users with random passwords and saves the credentials to a CSV file.

## Prerequisites
- ipa-client must be installed and properly configured.
- A valid Kerberos ticket is required (use kinit) and available for IdM administration.
- You have the necessary permissions to create users in the IdM realm.

## Inputs
- -c, --count N: Number of users to create (default: 3)
- -s, --start-index N: Starting index (default: 1)
- -p, --prefix STR: Username prefix (default: "u")
- -f, --firstname STR: Firstname prefix (default: "Test")
- -l, --lastname STR: Lastname prefix (default: "User")
- -d, --email-domain STR: Email domain to set (e.g., example.com)
- -S, --shell PATH: Login shell (default: /bin/bash)
- -g, --group NAME: Add each user to this existing IdM group (optional)
- -n, --dry-run: Show actions without creating users
- -h, --help: Show this help

## Usage examples
Real run:
```bash
./access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh -c 100 -s 501 -p u -f Test -l User -d example.com -S /bin/bash -g Interns
```

Dry-run example:
```bash
./access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh -c 5 -s 1 -p u -f Test -l User -d example.com -S /bin/bash -g Interns -n
```

## Outputs
- Credentials CSV: /root/new_idm_users_<timestamp>.csv (OUT_CSV). A header row is written: username,first,last,email,password
- Per-user lines are appended with: username,firstname,lastname,email,password
- On success: prints 'Created <USER>' for each created entry and 'Done. Credentials saved to: <CSV>'
- On DRY-RUN: actions are only printed to the console and not executed

## Security considerations
- Store the generated CSV securely and restrict access.
- Consider forcing password changes at first login (e.g., using ipa pwpolicy or user-mod attributes) after account creation.

## See also
- [`find_all_certs.sh`](identity_and_authentication/authenticator_management/find_all_certs.sh)
- [`rhel810-cve-check.sh`](system_and_info_integrity/malicious_code_protection/rhel810-cve-check.sh)
- [`cert_automated_test_script.sh`](identity_and_authentication/authenticator_management/cert_automated_test_script.sh)
- [`bulk_idm_user_create.sh`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh)