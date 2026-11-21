FROM mcr.microsoft.com/dotnet/sdk:10.0-noble

RUN if id ubuntu >/dev/null 2>&1; then userdel ubuntu; fi \
    && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi

RUN ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference = 'Stop'; Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Repository PSGallery -Scope AllUsers -Force"]
