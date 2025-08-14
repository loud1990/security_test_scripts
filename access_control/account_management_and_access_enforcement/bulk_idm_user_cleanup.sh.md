# Bulk IDM User Cleanup — usage guide

This document explains how to use the script [`access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh`](access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh) to delete a predefined set of IDM/FreeIPA users that were previously created.

## Prerequisites

- ipa-client must be installed and accessible on the host where you run the script.
- Kerberos ticket must be valid (e.g., kinit admin).
- You must have administrative rights in the IdM/FreeIPA directory.

## Inputs and modes

The script supports two input modes. Only one mode is used per invocation.

### 1) Deletion list from CSV (recommended when you have a known list)

Usage:
```
./access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh --from-csv /path/to/your.csv
```

Notes:
- The CSV must contain a header with a column named username (case-insensitive) or the first column is treated as the username.
- Commas or semicolons are accepted as separators. Blank and comment lines are ignored.
- The script will first verify that each username exists in IdM before attempting deletion.
- The script enforces safety checks, including dry-run and explicit confirmation unless --yes is provided.

Examples:
- Dry-run with a CSV:
```
./access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh --from-csv /root/new_idm_users_20250814-1010.csv --dry-run
```

- Real deletion with a CSV (assumes header includes username):
```
./access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh --from-csv /root/new_idm_users_20250814-1010.csv
```

### 2) Pattern-based deletion (create users with a predictable prefix)

Usage:
```
./access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh --prefix u --start-index 1 --count 1000
```

Notes:
- PAD controls zero-padding (default 4). The script uses padn to format numbers (e.g., u0001).
- You can override padding with --pad.
- The script will abort if no existing users are found among the targeted set.
- Interactive confirmation asks you to type DELETE N, unless --yes is supplied.

Examples:
- Dry-run with pattern:
```
./access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh --prefix u --start-index 1 --count 10 --dry-run --pad 4
```

- Real deletion with pattern (example):
```
./access_control/account_management_and_access_enforcement/bulk_idm_user_cleanup.sh --prefix u --start-index 1 --count 1000 --pad 4 --yes
```

## Outputs and interpretation

The script prints short, actionable messages. Important lines include:
- The following X usernames are targeted:
- Found in IdM: X
- Not found   : Y
- [DRY-RUN] Would run deletions for the X existing users above.
- Deleted USER
- FAILED to delete USER
- Done. All X users deleted. or Done with errors. Y deletions failed out of X.

## Practical interpretation

- The script never automatically deletes a user without explicit confirmation unless --yes is supplied.
- Use --dry-run first to validate the set of users before performing deletions.
- Keep a backup of the intended deletions (e.g., a CSV that contains the usernames).

## Related scripts

- Bulk user creation: [`access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh) and its docs: [`access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh.md`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh.md)

## Additional notes

- If you plan to run this against a production IdM, test in a sandbox environment first.
- Ensure your Kerberos ticket remains valid during the operation.

## See also

- Bulk creation docs: [`bulk_idm_user_create.sh.md`](access_control/account_management_and_access_enforcement/bulk_idm_user_create.sh.md)