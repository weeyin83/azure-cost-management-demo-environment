# A real, deliberately incurred cost-spike demo

This is an approved **overprovisioning drill**, not a change in Azure's prices,
organic application demand, guaranteed anomaly detection or genuine workload
optimization. No synthetic traffic, fake cost records or fake alerts are used.
Building/testing the tooling does not authorize deploying it or spending money.

## Agreed scenario and costs

Leave the estate on its current B1/one-worker plans for about ten days.
Then manually run the spike: both production and development plans become
Linux **S3, one worker each**, with Azure-hosted restoration scheduled
**20 hours after Start begins**. Production apps may briefly restart.
The databases, application packages and existing budgets are not changed.

Sweden Central public GBP reference rates checked 22 November 2026:

| Compute | Combined hourly net GBP |
|---|---:|
| Two B1 plans, one worker each | 0.0270 |
| Two S3 plans, one worker each | 0.5714 |
| Additional cost | 0.5444 |

Over 20 hours this adds **GBP 10.888 net / approximately GBP 13.07 with assumed
20% VAT**. Combined compute run rate is about 21 times baseline.
At 24 hours the additional reference compute is approximately **GBP 15.68 gross**.
The user preferred fewer workers to a more complex configuration closer to GBP 15.

The revised allowance is **GBP 20 extra**, including rollback headroom.
The script reprices the live region and rejects a 24-hour compute estimate plus
a **GBP 2 gross Automation reserve** above that allowance. The reserve is an
explicit planning allowance, not a verified Automation invoice or guaranteed cap.
Retail prices, VAT and billing agreements can differ. Do not assume subscription
free Automation minutes are unused. Small metric-alert/job charges can apply.

**Neither budgets nor the scheduler enforce a hard GBP 20 or 24-hour limit.**
Restoration is scheduled at 20 hours, with hourly retries beginning at 21 hours.
Retries continue until cleanup, including after 24 hours if recovery fails.
Azure outages, permission changes and scaling failures can delay restoration.
Monitor the job-failure email and perform manual recovery when required.
Stopping apps does not stop dedicated plan charges.

## Start baseline collection and connect Turbo360 first

1. After separately approving third-party onboarding, enable Turbo360 Cost
   Analyzer and use its documented read-only **Reader + Cost Management Reader**
   connection. Verify licence eligibility and scope; keep automatic actions OFF.
   Enter credentials only in its approved secure connection interface, not scripts,
   source control, chat or evidence snapshots.
2. Follow [Turbo360's quick start](https://docs.turbo360.com/docs/cost-analyzer-quick-start-1).
   Connect before collecting the baseline: its current documented limitations
   exclude cost history before connection. Check your actual edition's behavior.
3. Run the first import under **Settings > Cost imports > Run now**. Record the
   last successful import timestamp. Real-time cost data is not supported.
4. Create an estate cost group and daily actual-cost views for the two exact plan
   resource IDs. Add resource/service/group breakdowns and budget monitoring if
   your edition supports them. Configure Turbo360 notification channels separately.
5. In native Azure Cost Analysis, use matching dates, actual cost, currency and
   tax treatment. Production plan charges belong to **rg-finops-shared**, not
   rg-finops-production. The 40/40/20 portal allocation is labelled chargeback,
   not three additional Azure charges.
6. Open a subscription-scope Azure Cost Analysis **smart view** to onboard native
   anomaly detection. Its model uses 60 days of subscription history; ten days
   of this lab is not sufficient to promise a detection. Other subscription
   workloads can dilute or dominate the signal.
7. Save dated baseline cost screenshots/exports and the two B1 configurations.
   Do not change the estate or generate load during the baseline.

Cost data can take up to approximately 72 hours for PAYG, followed by Turbo360's
import delay. Native anomaly evaluation normally runs 36 hours after the UTC day
ends. A native Azure alert is not automatically a Turbo360 alert.

## Commands and approval gates

Use PowerShell 7.2+, the existing Azure CLI/Bicep tools and an explicit subscription.
Run from a connection already permitted by the apps' ingress rules.
Readiness checks will fail with 403 from an unapproved Codespaces/VPN egress IP.
Do not open ingress broadly to make this drill work.

```powershell
$subscription = '<your-subscription-guid>'
$emails = @('<approved-notification-email>')

# Read-only price and dedicated-budget preview. Wait for billed baseline data.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Inspect

# Preview guardrail intent; does not deploy or resize.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Prepare -NotificationEmails $emails -WhatIf

# SEPARATE cloud approval: Automation/runtime/runbook, two plan-scoped role
# assignments, failure metric alert and native anomaly alert if none exists.
# No plan resize or demo budget creation in Prepare.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Prepare -NotificationEmails $emails
```

Prepare checks project ownership, B1/one-worker baselines, region support,
possible outbound IP coverage in SQL/API rules, and all four readiness endpoints.
It uses an isolated Bicep deployment, not a root-estate redeployment.
Its managed identity can read/write **only the two selected plans**; it has no
SQL data-plane, application configuration or network permissions.
Prepare uploads/verifies the local runbook and executes a read-only verification
job. If identity propagation/runtime support fails, inspect that job; **do not
start the spike or grant broader Contributor permissions**.

Basic-to-Standard tier changes can affect outbound IPs. The existing Network
phase permits the app's possible outbound set; the drill verifies exact rules
rather than updating them. If coverage is stale, review a separately approved
Network update before retrying. Recheck runtime connectivity after each resize.

```powershell
# When ready to start, inspect again. Copy the CURRENT amountNetGbp.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Inspect
$reviewedAmount = <amountNetGbp-from-current-preview>

# Preview Start without mutations.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Start -NotificationEmails $emails `
    -ReviewedBudgetAmount $reviewedAmount -AcknowledgeIntentionalSpend -WhatIf

# SEPARATE spend approval. Prefer starting early in a UTC day.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Start -NotificationEmails $emails `
    -ReviewedBudgetAmount $reviewedAmount -AcknowledgeIntentionalSpend

./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Status
```

Start refuses missing/nonpositive/stale or non-GBP billed costs and month-boundary
starts. The dedicated monthly budget filters the two plan IDs. Its proposed net
amount includes observed month-to-date cost, an allowance for unreported baseline
usage, and half the estimated spike. The preview must be acknowledged exactly.
It is deliberately a demo budget: latency/pending charges mean its email timing
is not guaranteed. Existing subscription and RG budgets remain untouched.

Before any scale-up, Start stores recovery state in Azure, installs and reads back
both the 20-hour schedule and the hourly retry binding, and verifies the demo
budget. It rechecks both exact recovery role assignments and runs a fresh
managed-identity verification job before arming the spike.
It tags each resized plan with the run ID. Partial failure attempts to
restore both plans, without skipping production if development fails.
Run one operator/one lifecycle at a time; this is not a distributed job queue.
Do not resize/redeploy the plans or modify the Automation runbook while armed.

After successful Start, an ignored `.artifacts/cost-spike/<run-id>.json` snapshot
records the estimate, budget, UTC deadline, plan IDs and cleanup IDs. Azure
state/schedule parameters, not this file or a sleeping terminal, drive recovery.
Closing the terminal does not cancel the rollback.

## Verify the demo honestly

- Immediately: show both S3 plan configurations, Azure Activity Log and the
  rollback deadline. These demonstrate a configuration change, **not posted cost**.
- Later: after usage ingestion, show daily actual cost and the S3 meters in
  Azure; run a Turbo360 import and reconcile matching views.
- Show the dedicated budget email if it actually arrives. Show a **native anomaly**
  email only if Azure actually detects one. Do not relabel a budget notification.
- After rollback: verify both plans show B1/one worker, and all four
  `/health/ready` endpoints return `Healthy`. Scheduled runs do plan-level
  verification; operator-side Restore also checks network/readiness.
- Show the later drop in billed compute rate, not a fabricated realized saving.
  A spike crossing UTC midnight appears in more than one daily bar.

Status displays durable lifecycle state and job/schedule details. A scheduled
rollback does not rewrite the operator's `Active` lifecycle label: inspect live
plan SKUs, run-owner tags and completed job output for the actual result.
Use Restore to reconcile that label and perform the readiness checks.

## Emergency restore and targeted cleanup

```powershell
# Safe to repeat; attempts both plans independently and verifies B1/one worker.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Restore

# Save the local snapshot plus Automation output, cost/alert evidence first.
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Cleanup -WhatIf
./scripts/Invoke-CostSpikeDemo.ps1 -SubscriptionId $subscription `
    -BillingCurrency GBP -Phase Cleanup
```

An unexpected SKU/worker count or run-owner tag fails recovery rather than
overwriting someone else's change. Inspect the exact plan, role permissions and
job error stream before manually restoring it:

```powershell
# Use only the two verified plan names/groups from the captured state.
az appservice plan update --subscription $subscription `
    --resource-group '<verified-plan-group>' --name '<verified-plan-name>' `
    --sku B1 --number-of-workers 1
```

Recheck project ownership and remove only the `CostSpikeRun` tag after verifying
the baseline; then run Restore/Status. If connectivity fails, review possible
outbound addresses, the exact SQL firewall and portal-to-API ingress. Do not
change databases, grant db_owner or add broad Allow Azure Services rules.

Cleanup requires baseline restoration and removes only the dedicated budget,
demo-owned anomaly alert, failure alert, two role assignments, custom role and
Automation account (including its schedules). Existing anomaly alerts are
preserved. The account is deleted last to preserve state on earlier failures.
If cleanup was interrupted, inspect the remaining exact IDs in the snapshot;
do not delete whole resource groups or retry by ignoring unrelated errors.
Subscription deployment history remains. Reconcile final charges after ingestion.
Perform cleanup promptly: otherwise the hourly no-op retry jobs still run.

## Offline verification

```powershell
pwsh -NoProfile -File ./tests/CostSpikeDemo.Tests.ps1
pwsh -NoProfile -File ./tests/DeploymentPaths.Tests.ps1
pwsh -NoProfile -File ./tests/DeploymentRegion.Tests.ps1
az bicep build --file ./infra/modules/cost-spike-automation.bicep --stdout
```

Mocks prove orchestration/error handling, not Azure capacity, runtime support,
managed-identity authorization, scheduler execution, actual costs or email
delivery. Those require separately approved live Prepare/verification and the
explicitly approved paid Start.

Sources: [native anomalies](https://learn.microsoft.com/en-us/azure/cost-management-billing/understand/analyze-unexpected-charges),
[budget evaluation](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/manage-automation),
[Automation schedules](https://learn.microsoft.com/en-us/azure/automation/shared-resources/schedules),
[Automation job alerts](https://learn.microsoft.com/en-us/azure/automation/automation-alert-metric),
[outbound IP behavior](https://learn.microsoft.com/en-us/azure/app-service/overview-inbound-outbound-ips),
[public pricing](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices).
