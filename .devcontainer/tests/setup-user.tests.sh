#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Container directory setup test failed at line %s.\n" "$LINENO" >&2' ERR

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d)"
cleanup() {
    rm -f -- "$temp_dir/bin/sudo" "$temp_dir/bin/mkdir" "$temp_dir/bin/dotnet" \
        "$temp_dir/bin/pwsh" "$temp_dir/bin/az" "$temp_dir/bin/bicep" "$temp_dir/bin/gh" \
        "$temp_dir/home/.nuget/NuGet/NuGet.Config" "$temp_dir/home/.bashrc" \
        "$temp_dir/home/.config/contoso-finops/env.sh" "$temp_dir/audit" "$temp_dir/output"
    rmdir -- "$temp_dir/home/.nuget/packages" "$temp_dir/home/.nuget/NuGet" \
        "$temp_dir/home/.nuget" "$temp_dir/home/.bicep" \
        "$temp_dir/home/.config/contoso-finops" "$temp_dir/home/.config" \
        "$temp_dir/workspace/src/ContosoFinOps/bin" "$temp_dir/workspace/src/ContosoFinOps/obj" \
        "$temp_dir/workspace/tests/ContosoFinOps.Tests/bin" "$temp_dir/workspace/tests/ContosoFinOps.Tests/obj" \
        "$temp_dir/workspace/src/ContosoFinOps" "$temp_dir/workspace/src" \
        "$temp_dir/workspace/tests/ContosoFinOps.Tests" "$temp_dir/workspace/tests" \
        "$temp_dir/workspace" "$temp_dir/home" "$temp_dir/bin" "$temp_dir"
}
trap cleanup EXIT
mkdir -p "$temp_dir/bin" "$temp_dir/home/.nuget/NuGet" "$temp_dir/workspace"
printf '<configuration><!-- retain custom feeds and credentials --></configuration>\n' \
    > "$temp_dir/home/.nuget/NuGet/NuGet.Config"
original_hash="$(sha256sum "$temp_dir/home/.nuget/NuGet/NuGet.Config")"

cat > "$temp_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tool="$(basename "$0")"
printf '%s' "$tool" >> "$AUDIT_LOG"
printf ' %s' "$@" >> "$AUDIT_LOG"
printf '\n' >> "$AUDIT_LOG"
case "$tool" in
    sudo)
        export IN_TEST_SUDO=1
        exec "$@"
        ;;
    mkdir)
        for argument in "$@"; do
            if [[ "$argument" == "$HOME/.nuget" || "$argument" == "$HOME/.nuget/"* ]]; then
                if [[ "${IN_TEST_SUDO:-0}" != "1" ]]; then
                    printf "Simulated root-owned NuGet directory requires privileged preparation.\n" >&2
                    exit 77
                fi
            fi
        done
        exec /usr/bin/mkdir "$@"
        ;;
    dotnet)
        if [[ "${1:-}" == "--list-sdks" ]]; then
            printf '10.0.404 [/usr/share/dotnet/sdk]\n'
        else
            [[ -r "$HOME/.nuget/NuGet/NuGet.Config" ]]
            [[ -w "$HOME/.nuget/NuGet" ]]
        fi
        ;;
    pwsh|az|bicep|gh) ;;
    *) exit 78 ;;
esac
EOF
for tool in mkdir dotnet pwsh az bicep gh; do
    cp -- "$temp_dir/bin/sudo" "$temp_dir/bin/$tool"
done
chmod +x "$temp_dir/bin/sudo" "$temp_dir/bin/mkdir" "$temp_dir/bin/dotnet" \
    "$temp_dir/bin/pwsh" "$temp_dir/bin/az" "$temp_dir/bin/bicep" "$temp_dir/bin/gh"

(
    export HOME="$temp_dir/home"
    export PATH="$temp_dir/bin:$PATH"
    export AUDIT_LOG="$temp_dir/audit"
    export ACCEPT_EULA=Y
    export MSSQL_SA_PASSWORD="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')aA1!"
    cd -- "$temp_dir/workspace"
    bash "$script_dir/../setup-user.sh" > "$temp_dir/output"
    bash "$script_dir/../setup-user.sh" >> "$temp_dir/output"
)
[[ "$(sha256sum "$temp_dir/home/.nuget/NuGet/NuGet.Config")" == "$original_hash" ]]
[[ "$(grep -Fc 'source "$HOME/.config/contoso-finops/env.sh"' "$temp_dir/home/.bashrc")" == "1" ]]
restore_line="$(grep -n '^dotnet tool restore$' "$temp_dir/audit" | head -n 1 | cut -d: -f1)"
for path in "$temp_dir/home/.nuget" "$temp_dir/home/.nuget/NuGet" "$temp_dir/home/.nuget/NuGet/NuGet.Config"; do
    repair_line="$(grep -Fn "sudo chown -- $(id -u):$(id -g) $path" "$temp_dir/audit" | head -n 1 | cut -d: -f1)"
    [[ -n "$repair_line" && "$repair_line" -lt "$restore_line" ]]
done
printf "Container setup tests passed: privileged NuGet parent preparation before restore, configuration preservation and repeatable setup. CLI tools were mocked.\n"
