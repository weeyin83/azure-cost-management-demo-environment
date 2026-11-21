#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Container setup failed at line %s.\n" "$LINENO" >&2' ERR

if [[ "${ACCEPT_EULA:-}" != "Y" ]]; then
    printf "Set ACCEPT_EULA=Y only after reviewing the SQL Server licence.\n" >&2
    exit 1
fi
password="${MSSQL_SA_PASSWORD:-}"
if [[ ! "$password" =~ ^[A-Za-z0-9+/_=.!-]{20,128}$ ]] ||
   [[ ! "$password" =~ [A-Z] ]] || [[ ! "$password" =~ [a-z] ]] ||
   [[ ! "$password" =~ [0-9] ]] || [[ ! "$password" =~ [+/=_.!-] ]]; then
    printf "Set a strong local SQL password using the documented character set; do not use quotes or semicolons.\n" >&2
    exit 1
fi
unset password

paths=(
    "$HOME/.nuget"
    "$HOME/.nuget/NuGet"
    "$HOME/.nuget/packages"
    "$HOME/.bicep"
    "$PWD/src/ContosoFinOps/bin"
    "$PWD/src/ContosoFinOps/obj"
    "$PWD/tests/ContosoFinOps.Tests/bin"
    "$PWD/tests/ContosoFinOps.Tests/obj"
)
owner="$(id -u):$(id -g)"
for path in "${paths[@]}"; do
    if sudo test -L "$path"; then
        printf "Refusing to change ownership of a symbolic-link directory: %s\n" "$path" >&2
        exit 1
    fi
    sudo mkdir -p -- "$path"
    sudo chown -- "$owner" "$path"
    sudo chmod u+rwx -- "$path"
done

nuget_config="$HOME/.nuget/NuGet/NuGet.Config"
if [[ -e "$nuget_config" || -L "$nuget_config" ]]; then
    if [[ ! -f "$nuget_config" || -L "$nuget_config" ]]; then
        printf "NuGet.Config must be a regular local file; existing configuration was preserved.\n" >&2
        exit 1
    fi
    sudo chown -- "$owner" "$nuget_config"
    sudo chmod u+rw -- "$nuget_config"
fi

mkdir -p "$HOME/.config/contoso-finops"
cat > "$HOME/.config/contoso-finops/env.sh" <<'EOF'
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=true
export AZURE_CORE_CHECK_VERSION=false
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no
export AZURE_BICEP_USE_BINARY_FROM_PATH=true
EOF
source_line='source "$HOME/.config/contoso-finops/env.sh"'
touch "$HOME/.bashrc"
if ! grep -Fqx "$source_line" "$HOME/.bashrc"; then
    printf '\n%s\n' "$source_line" >> "$HOME/.bashrc"
fi

dotnet --list-sdks | grep -q '^10\.'
pwsh -NoLogo -NoProfile -NonInteractive -Command \
    'Import-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -ErrorAction Stop'
az --version
bicep --version
gh --version
dotnet tool restore
dotnet restore ContosoFinOps.slnx
bicep restore infra/main.bicep
printf "Tools and project caches prepared. Build, tests, local database initialization and Azure actions remain explicit.\n"
