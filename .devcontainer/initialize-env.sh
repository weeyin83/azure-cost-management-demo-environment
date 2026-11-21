#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Local SQL credential initialization failed at line %s.\n" "$LINENO" >&2' ERR

container_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="$container_dir/.env"
umask 077

if [[ ! -e "$env_file" && ! -L "$env_file" ]]; then
    random="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ ! "$random" =~ ^[a-f0-9]{64}$ ]]; then
        printf "Could not generate a secure local SQL password.\n" >&2
        exit 1
    fi
    password="${random}aA1!"
    (
        set -o noclobber
        printf '# Generated development-only credentials; never commit this file.\nACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\n' "$password" > "$env_file"
    )
    if [[ "$(id -u)" == "0" ]]; then
        chown --reference="$container_dir" "$env_file"
    fi
    unset random password
    printf "Created ignored local SQL credentials. SQL Server Developer licence acceptance was approved for this project.\n"
fi

if [[ ! -f "$env_file" || -L "$env_file" ]]; then
    printf ".devcontainer/.env must be a regular local file, not a symbolic link.\n" >&2
    exit 1
fi

accept_eula="$(awk -F= '$1 == "ACCEPT_EULA" { value = substr($0, index($0, "=") + 1); sub(/\r$/, "", value) } END { print value }' "$env_file")"
password="$(awk -F= '$1 == "MSSQL_SA_PASSWORD" { value = substr($0, index($0, "=") + 1); sub(/\r$/, "", value) } END { print value }' "$env_file")"
if [[ "$accept_eula" != "Y" ]]; then
    printf "Existing .devcontainer/.env was preserved. Set ACCEPT_EULA=Y only if you accept the SQL Server Developer licence.\n" >&2
    exit 1
fi
if [[ ! "$password" =~ ^[A-Za-z0-9+/_=.!-]{20,128}$ ]] ||
   [[ ! "$password" =~ [A-Z] ]] || [[ ! "$password" =~ [a-z] ]] ||
   [[ ! "$password" =~ [0-9] ]] || [[ ! "$password" =~ [+/=_.!-] ]]; then
    printf "Existing .devcontainer/.env was preserved. Supply a strong SQL password using the documented character set.\n" >&2
    exit 1
fi
unset accept_eula password
printf "Local SQL configuration is ready before Docker Compose runs; existing credentials are never overwritten.\n"
