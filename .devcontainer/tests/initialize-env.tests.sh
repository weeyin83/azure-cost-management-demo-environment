#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Credential initialization test failed at line %s.\n" "$LINENO" >&2' ERR

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -f -- "$temp_dir/.env" "$temp_dir/initialize-env.sh" "$temp_dir/output"; rmdir -- "$temp_dir"' EXIT
cp -- "$script_dir/../initialize-env.sh" "$temp_dir/initialize-env.sh"

bash "$temp_dir/initialize-env.sh" > "$temp_dir/output"
[[ -f "$temp_dir/.env" ]]
grep -qx 'ACCEPT_EULA=Y' "$temp_dir/.env"
password="$(sed -n 's/^MSSQL_SA_PASSWORD=//p' "$temp_dir/.env")"
[[ "$password" =~ ^[a-f0-9]{64}aA1!$ ]]
! grep -Fq "$password" "$temp_dir/output"
first_password="$password"
first_hash="$(sha256sum "$temp_dir/.env")"
bash "$temp_dir/initialize-env.sh" > "$temp_dir/output"
[[ "$(sha256sum "$temp_dir/.env")" == "$first_hash" ]]

rm -- "$temp_dir/.env"
bash "$temp_dir/initialize-env.sh" > "$temp_dir/output"
password="$(sed -n 's/^MSSQL_SA_PASSWORD=//p' "$temp_dir/.env")"
[[ "$password" != "$first_password" ]]

printf 'ACCEPT_EULA=\nMSSQL_SA_PASSWORD=invalid\n' > "$temp_dir/.env"
invalid_hash="$(sha256sum "$temp_dir/.env")"
if bash "$temp_dir/initialize-env.sh" > "$temp_dir/output" 2>&1; then
    printf "Invalid existing configuration was incorrectly accepted.\n" >&2
    exit 1
fi
[[ "$(sha256sum "$temp_dir/.env")" == "$invalid_hash" ]]
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=invalid\n' > "$temp_dir/.env"
invalid_hash="$(sha256sum "$temp_dir/.env")"
if bash "$temp_dir/initialize-env.sh" > "$temp_dir/output" 2>&1; then
    printf "An invalid existing password was incorrectly accepted.\n" >&2
    exit 1
fi
[[ "$(sha256sum "$temp_dir/.env")" == "$invalid_hash" ]]
printf "Credential initialization tests passed: fresh clone, repeatability, unique passwords, no disclosure and preservation of invalid user input.\n"
