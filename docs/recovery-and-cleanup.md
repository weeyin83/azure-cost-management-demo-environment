# Recovery, permissions and cleanup

Nothing in this document authorizes deployment, live database writes, restores
or teardown. All scripts require an explicit subscription and their own relevant
approval; confirmation/what-if are safeguards, not spending limits.

## SQL initialization

Bicep establishes Entra-only SQL administration and app identities. A contained
database user and data-plane grants still need explicit administrator bootstrap.
Allow the approved administrator's public IPv4 temporarily, sign in as a member
of the configured SQL administrator group, then initialize production and
development explicitly. The local CLI initializer authenticates via Active
Directory Default (including the approved Azure CLI login); it does not use the
application's runtime identity to change schema. No credentials are embedded.

The generated SQL migration script is reviewable in `scripts\sql\migrations.sql`.
Initialization is an explicit CLI mode of the existing .NET package, rather
than a new sqlcmd/PowerShell SQL-module installation or a public web route.
On failure, the PowerShell exception includes the .NET exit code and captured
standard output/error, even if the caller discards normal script output. Use the
underlying build, authentication or SQL error to diagnose the failure; the wrapper's
failure message alone does not identify the cause. If no diagnostic output is
emitted, verify that the selected .NET executable is allowed to run under local
application-control policy. A nonzero exit never confirms schema or runtime
success; earlier migration steps may already have completed. Remove temporary
administrator network access on failure as well as success.
`grant-database-access.sql` checks SID/type and excess roles/grants before
granting SELECT/INSERT/UPDATE/DELETE on `dbo.Todo`. Initialization resolves the
selected managed identity service principal read-only, checks its object ID/
display name, and uses its application/client ID for SQL SID verification.
Creation uses `FROM EXTERNAL PROVIDER` and therefore requires working directory
resolution; no Directory Readers grant or lookup-bypassing fallback is automated.
The actual tenant provisioning path still requires validation. An ambiguous
display name must be resolved explicitly, not associated with an arbitrary
principal. `seed-demo.sql` explicitly seeds
30 reserved fictional descriptions transactionally; reruns insert missing rows
only. No public reset or startup initialization exists.

After initialization run Network without a bootstrap address, changing the
existing bootstrap rule to a disabled broadcast address. Incremental Bicep
omission would not remove it. Verify no actual administrator IPv4 remains and
no Azure-wide rule exists. If tenant identity or networking fails, stop and
resolve it; do not open all SQL traffic or grant `db_owner`/Directory Readers
as a fallback.

## Recovery capabilities

| Component | Protection | Limitation |
|---|---|---|
| Production Basic SQL | 7-day PITR, GRS backups | No live geo replica or zone failover; Basic max 2 GB/5 DTU |
| Development Basic SQL | 1-day PITR, LRS backups | Shorter recovery window; independent from production |
| Report exports | Hot ZRS, private Blob; 7-day soft delete; 30-day report lifecycle | Not a backup of SQL or whole-estate resilience; soft-deleted storage still costs |
| Application/templates | Pinned upstream source + adapted source in [GitHub](https://github.com/weeyin83/azure-cost-management-demo-environment), with automated build/tests | Source control and tests do not back up databases, credentials or deployment packages |
| Logs | Shared 30-day retention and sampling | Cap can blind monitoring; telemetry is not application data backup |

Automated DTU PITR backup storage is included under the documented allowance;
LTR is not configured. Production GRS is backup durability, not automatic
application failover. Basic retention supports 1-7 days. Deleting the SQL
logical server removes normal PITR recovery, even if a backup setting looked
protective. Export required evidence/data before deletion.
Source: [SQL automated backups](https://learn.microsoft.com/en-us/azure/azure-sql/database/automated-backups-overview?view=azuresql).

## Separately approved PITR drill

Choose a restore point within the source's *actual* available range, a unique
`orders-restore-...` destination and explicit Basic or S3 tier. Never overwrite
`orders`. Restore creates a charged temporary database; Basic might require
a temporary Standard tier. Neither 8 hours nor any other estimate promises RTO.

```powershell
.\scripts\Restore-DemoDatabase.ps1 -SubscriptionId $subscription -Environment Production `
    -RestoreTime $approvedUtcRestorePoint -Destination orders-restore-approveddrill -Tier S3
```

Inspect restored schema/rows and selected tags as administrator; do not repoint
production automatically. Record elapsed recovery, data timestamp and cost.
Restore/user replication must not be assumed until checked. Delete only that
named temporary DB through separately approved CLI action afterward:

```powershell
az sql db delete --subscription $subscription --resource-group rg-finops-production `
    --server $actualProductionServer --name orders-restore-approveddrill
```

This is a read/write drill, not part of read-only `Test-Deployment.ps1`.
Native cost/telemetry exports may need separate container roles or supported
trusted-service settings; they are not auto-configured merely because a private
`cost-exports` container exists. Do not enable shared keys broadly as a workaround.

## Package recovery and validation

Retain the upstream pin, licence notices, adapted source, generated migration SQL
and an explicitly built deployment ZIP in an approved backup location. Source
is versioned in GitHub; ignored credentials, local data and deployment packages
require their own secure recovery arrangements. CI runs build/tests only;
no automatic Azure publication is configured. Rebuild .NET 10,
rerun tests on an approved execution host, compile Bicep/profiles, then review
deployment what-if. Republish the API before portals; do not change database
identity/configuration implicitly during source recovery.

Current evidence: the Linux CI build has zero warnings/errors and all 21
application integration tests pass with in-memory databases and in-process HTTP
([CI run](https://github.com/weeyin83/azure-cost-management-demo-environment/actions/runs/44936675095)).
EF reports no pending model changes and emits offline idempotent SQL.
This Windows host's local test execution remains blocked by Application Control;
no Windows policy or trust changes were made. Real SQL migrations, managed
identity, Blob export, ingress and the Turbo trial remain unverified at runtime.

Later Stage 4 checks include valid/invalid CRUD, anti-forgery, role exclusion,
production/dev isolation, retry/dependency errors, SQL grants, Blob uploads,
HTTPS/publishing restrictions, actual tags, PITR limits, logs/alerts, raw costs,
allocation and free Turbo capability. Do not label mock/in-memory tests as proof
of SQL Server, Entra, Blob or Azure networking.

## Teardown safeguards

Export evidence first. Review all three exact groups and project tags. Script
preflight stops if it finds unrelated/untagged resources; child/configuration
tag exceptions are explicit. No wildcards, broad filesystem deletion or active
subscription switching is used.

```powershell
.\scripts\Teardown.ps1 -SubscriptionId $subscription -AcknowledgeRecoveryLoss -WhatIf
.\scripts\Teardown.ps1 -SubscriptionId $subscription -AcknowledgeRecoveryLoss
```

Deletion waits and verifies group absence. Blob exports/logs are deleted with
their shared group, and normal SQL PITR disappears with its servers.
Subscription-scoped named project/RG-filter budgets and deployment history
remain unless explicitly reviewed/deleted separately. Search for retained
temporary restores, independently configured exports/schedules and residual
resources; a zero-resource group view alone is not final billing proof.
Stopping apps before teardown does not stop plan or Basic SQL charges.
