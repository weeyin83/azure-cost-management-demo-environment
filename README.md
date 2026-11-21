# Contoso Services FinOps lab

An economical, region-configurable demonstration of native Azure Cost Management and Turbo360.
One maintained MIT-licensed .NET 10 MVC/SQL application is reused in four roles;
this is not four applications written from scratch. Source and attribution:
[NOTICE.md](NOTICE.md).
Dependency notices are preserved; the Windows native SQL SNI dependency has
Microsoft redistribution terms rather than MIT. Azure publication targets
framework-dependent Linux and excludes those Windows native binaries.

Source repository: [weeyin83/azure-cost-management-demo-environment](https://github.com/weeyin83/azure-cost-management-demo-environment).

**Status:** local application/infrastructure/scripts exist. The solution builds
and EF migration SQL can be generated offline. This host's Application Control
blocks the test runner from loading the compiled application; automated runtime
tests have NOT passed. No Azure resources have been deployed or validated.
Deployment remains a separate approval gate, not an implied next action.

## Layout

| Path | Purpose |
|---|---|
| `src\ContosoFinOps` | Reused Razor UI, SQL-backed API, reports, four isolated deployment roles |
| `infra` | Three resource groups, pinned AVM modules and explicit economical settings |
| `scripts` | Manual, subscription-explicit inspection/deployment/recovery/cleanup |
| `tests\ContosoFinOps.Tests` | API, role isolation, HTTP dependency, anti-forgery and CSV tests |
| `.devcontainer` | .NET 10/Bicep development environment and private local SQL Server |
| `docs` | [Architecture](docs/architecture.md), [costs](docs/cost-management.md), [recovery](docs/recovery-and-cleanup.md) |

## Dev container

Adapted from your `weeyin83/dev-container-template` conventions, using the official
.NET 10 Ubuntu 24.04 SDK image. It already contains PowerShell, so a second
PowerShell/.NET installation is avoided. Azure CLI/Bicep, GitHub CLI and
PSScriptAnalyzer are installed at image build time. Terraform, Node.js, Docker
in Docker, Kubernetes and HTML Live Server are not added.

Prerequisites: an approved Docker/Compose installation, VS Code with Dev
Containers, an x86-64 host and roughly 6 GB available RAM/12 GB storage for the
whole stack. The bundled SQL Server 2022 Developer image is for development only;
ARM emulation is not a supported SQL Server configuration. Use a reviewed
supported external SQL source for ARM instead. Docker is not installed on the
current host, so the container has not been built or started here.

The project owner explicitly accepted [Microsoft's SQL Server Developer
container licence](https://learn.microsoft.com/en-us/sql/linux/quickstart-install-connect-docker?view=sql-server-ver17)
for this environment. Community users must review those terms before using the
SQL container. On the host, `initializeCommand` generates an ignored
`.devcontainer/.env` **before Docker Compose reads it**, including
`ACCEPT_EULA=Y` and a unique password from 32 OS-random bytes. Fresh Codespaces
clones therefore do not need a pre-existing secret file. No password is printed,
committed or sent to Azure; the Docker build context also excludes `.env`.
The hook preserves and validates existing credentials rather than resetting
them, including on rebuild. Back up local data and its credentials together:
deleting `.env` while retaining SQL's data volume does not reset the database's
existing password.

For your own credentials, copy `.devcontainer/.env.example` to `.env` before
opening the container and populate it explicitly. Invalid existing files fail
with an actionable error and are not overwritten. Keep `.env` private. Passwords use
20-128 characters from letters/digits and `+ / _ = . ! -`; quotes/semicolons are
excluded to keep the local connection string unambiguous. `.gitignore` excludes
real `.env` files, local credentials/parameters, build outputs and exports while
retaining `.env.example`. Local credentials are not part of the source repository.

Choose **Dev Containers: Reopen in Container**, or create a Codespace from the
repository. For an existing Codespace stuck in recovery, update its checkout
with the fix and choose **Codespaces: Rebuild Container**. Host prerequisites
include Bash and standard `od`/`tr`/`awk` utilities (present on Codespaces hosts
and Git Bash); no additional host package installation is performed.
Initial container creation restores
NuGet packages, the pinned EF tool and public Bicep modules only. Opening an
existing container does not reinstall tools. Named caches and Linux-native
bin/obj volumes reduce Windows bind-mount I/O and avoid sharing Windows build
artifacts. SQL has a persistent data volume, a 2 GB SQL memory target/3 GB
container limit and no published host port. VS Code forwards application ports
5100-5103; keep Codespaces ports private.

Use the explicit **Initialize LOCAL database (writes schema)** task once, then
**Build**, **Test**, and the run tasks. Run Orders API before the customer/reporting
portals. All local roles share the `ContosoFinOps` development DB; Azure
production/development remain separate. The creation hook does not apply
migrations, seed records, launch apps, sign into Azure or deploy anything.

To seed locally after schema initialization, use the SQL container's included
sqlcmd from a host Docker terminal (substitute the actual running SQL container
name from `docker ps`; do not select an unrelated container):

```powershell
docker exec $sqlContainer bash -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -d ContosoFinOps -i /seed/seed-demo.sql -b'
```

Closing the environment stops its Compose services but retains caches/database
data. Deliberately removing its named SQL volume destroys that local database;
do not use blanket volume pruning. SDK/image and feature-major tags receive
updates on deliberate rebuild, not byte-identical pinned-digest reproduction.
Codespaces creation/prebuilds can consume billable quota and are not started here.
The configuration is an intended development path, not a claim that the Windows
test blocker or container runtime behavior has already been verified.

If an existing container reports unauthorized access to
`/home/vscode/.nuget/NuGet/NuGet.Config`, update the checkout and rerun
`bash .devcontainer/setup-user.sh`. Setup repairs the NuGet parent directories,
cache mount roots and any existing NuGet.Config for the container user before
restoring tools/packages. It preserves configuration contents and does not
recursively change the home directory, remove caches or touch SQL data. New
containers receive the repair through the normal creation hook.
The local database task also runs **Restore tools** first, so `dotnet-ef` is
available before migrations are attempted.

Offline setup/preflight regression checks (no Docker or Azure access):

```powershell
bash .devcontainer/tests/initialize-env.tests.sh
bash .devcontainer/tests/setup-user.tests.sh
pwsh -NoProfile -File .\tests\DeploymentRegion.Tests.ps1
```

## Local prerequisites and build

Use .NET SDK 10, PowerShell 7.2+, Azure CLI with an approved Bicep component, and
SQL Server LocalDB or another explicitly configured development SQL instance.
Do not install prerequisites, change execution policy or create Azure resources
as a workaround without permission. No Git repository or CI/CD is required.

```powershell
dotnet tool restore
dotnet build .\ContosoFinOps.slnx
dotnet test .\ContosoFinOps.slnx
$env:ASPNETCORE_ENVIRONMENT = 'Development'
dotnet ef migrations has-pending-model-changes --project .\src\ContosoFinOps
dotnet ef migrations script --idempotent --project .\src\ContosoFinOps
az bicep build --file .\infra\main.bicep --outfile "$env:TEMP\contoso-main.json"
az bicep build --file .\infra\modules\network-access.bicep --outfile "$env:TEMP\contoso-network.json"
```

The upstream EF migrations are retained. The new migration adds category,
status and timestamps; it does not truncate existing descriptions. New requests
are limited to 500 characters at the application boundary. Review migration SQL:
the old upstream simplification migration drops old optional fields, so do not
apply its entire history to an unrelated/legacy database without reviewing it.
No startup schema migration or public seed/reset endpoint exists.

LocalDB's non-secret integrated-authentication default is in development settings.
For another local SQL instance, configure `ConnectionStrings:Orders` with user
secrets or a process-local environment variable; never commit credentials.
Schema creation is an explicit local database write:

```powershell
$env:ASPNETCORE_ENVIRONMENT = 'Development'
dotnet ef database update --project .\src\ContosoFinOps
dotnet run --project .\src\ContosoFinOps --launch-profile OrdersAPI
```

Run the CustomerPortal and ReportingPortal profiles in separate terminals to
use that API (ports 5102 and 5103 -> 5101). DevelopmentPortal (5100) instead
combines frontend/API/SQL. This local four-role preview shares one local DB;
Azure uses separate production and development databases. Local reports download
CSV without Blob upload when no storage URI is configured. In Azure, Blob
configuration is mandatory and uses the reporting app's managed identity.

Orders API: `GET/POST /api/orders`, `GET/DELETE /api/orders/{id}`,
`PUT /api/orders/{id}/status` and `GET /api/orders/summary`.
Create JSON: `{"description":"Inspect meeting room","category":"Facilities"}`.
Status JSON: `{"status":"Completed"}`. Categories: IT, Facilities, Consulting.
States: Open, InProgress, Completed. Lists/CSV show the latest 200; summary counts
cover all rows. Health: `/health/live` (process) and `/health/ready` (dependencies).

## Manual Azure sequence - only after separate approval

Scripts do not execute on build, import, or application startup. Every cloud
script requires the actual subscription ID; it does not change the active CLI
subscription. All authenticated reads, what-if and subsequent writes require
their respective permission. `-WhatIf` does not eliminate preflight reads.

Supply these process-local deployment inputs securely:
`CONTOSO_LOCATION`, `CONTOSO_PREFIX`, `CONTOSO_SQL_ADMIN_OBJECT_ID`, `CONTOSO_SQL_ADMIN_NAME`,
`CONTOSO_TENANT_ID`, `CONTOSO_BUDGET_EMAILS` (comma-separated).
`CONTOSO_LOCATION` is required for both Bicep profiles and the Inspect/Create
phases; there is no default region or automatic capacity fallback. Use a
canonical lowercase Azure region code. For example, `$env:CONTOSO_LOCATION =
'westeurope'` selects West Europe, but is not a claim of available capacity or
an approved replacement region.
The SQL administrator defaults to an Entra group; use a reviewed local parameter
file for a different supported principal type. All-zero/synthetic compilation
values are not valid deployment inputs. Confirm GBP billing/VAT and prices;
`-BillingCurrency GBP` is a user assertion, not proof from the billing account.

```powershell
# Set CONTOSO_LOCATION to your reviewed region before running these commands.
.\scripts\Deploy.ps1 -SubscriptionId $subscription -BillingCurrency GBP -Phase Inspect
.\scripts\Deploy.ps1 -SubscriptionId $subscription -BillingCurrency GBP -Phase Create -CostEstimateReviewed
.\scripts\Deploy.ps1 -SubscriptionId $subscription -BillingCurrency GBP -Phase Network `
    -ApprovedAddresses $approvedCidrs -BootstrapAdministratorAddress $approvedAdministratorIPv4
.\scripts\Initialize-Database.ps1 -SubscriptionId $subscription -Environment Production -Seed
.\scripts\Initialize-Database.ps1 -SubscriptionId $subscription -Environment Development -Seed
.\scripts\Deploy.ps1 -SubscriptionId $subscription -BillingCurrency GBP -Phase Network `
    -ApprovedAddresses $approvedCidrs
.\scripts\Deploy.ps1 -SubscriptionId $subscription -BillingCurrency GBP -Phase Publish -DatabaseInitializationConfirmed
.\scripts\Test-Deployment.ps1 -SubscriptionId $subscription
```

Inspect actual subscription quota, SQL provisioning/administrator rights,
selected-region stamp/runtime support and the exact what-if. Preflight checks
the region, Linux B1 (and B2 for the opt-in profile), Basic SQL and StorageV2
Standard_ZRS support. These listings do not reserve capacity or guarantee that
provisioning will succeed. Unsupported profiles fail rather than silently
downgrading SKUs or storage redundancy. Existing estate groups in another
region require reviewed migration/cleanup; changing a parameter does not move
resources. Network, Publish and ResizeDevelopment use the existing estate and
do not require a new region selection. Bicep creates closed app
ingress and SQL without broad firewall rules. Network phase queries current
possible egress and preserves existing web configuration; allow production
portal egress to the API and only API/dev egress to the appropriate SQL server.
SCM permits only approved administrative CIDRs. No broad Allow Azure Services,
public containers, SQL passwords or Entra *user-sign-in* are enabled.

Network restriction is a trusted filming lab profile, not production customer
authentication. Shared-plan outbound IPs are not per-app authentication.
Runtime identities have CRUD on `dbo.Todo` only; customer/reporting portals have
no SQL identity grants. Reporting Blob access is container-scoped.

The **UK South reference** estimate is **GBP 38.21/month including assumed 20% VAT**,
with an operating allowance of GBP 40-45. Reprice the selected region before
approving deployment against the preferred GBP 50 target / GBP 100 desired
ceiling; the UK South figures are not a quote for other regions.
Budgets notify, not cap spending. One-worker
B1 and Basic SQL are not zone resilient. Stopping apps does not stop plan charges.
See the cost document for assumptions, allocation and real-data/Turbo gates.
