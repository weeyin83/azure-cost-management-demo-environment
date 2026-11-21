# Cost estimate, allocation and demonstration evidence

These are reference PAYG estimates, not actual billing data or binding quotes.
Checked 21 November 2026 against the public Azure Retail Prices API: UK South,
GBP, consumption prices, 730 hours/month, no credits/reservations/licence benefit,
assumed 20% VAT. Non-USD Retail API prices are reference estimates; verify the
actual billing agreement, currency, tax treatment and quota before deployment.
Turbo360's supplied free licence is assumed to add no subscription fee, but
feature eligibility is not yet verified.

## Normal monthly estimate

| Charge | Meter/SKU and assumption | Net GBP |
|---|---|---:|
| Fixed: production compute | Linux B1, 1 worker x 730 h x 0.0135 | 9.8550 |
| Fixed: development compute | Linux B1, 1 worker x 730 h x 0.0135 | 9.8550 |
| Fixed: production SQL | Basic/B DTU, (730/24) days x 0.1511 | 4.5960 |
| Fixed: development SQL | Basic/B DTU, same | 4.5960 |
| Variable: log ingestion | 1 payable GB x 2.1653 | 2.1653 |
| Variable: Hot ZRS Blob | 5 GB x 0.018; 10k writes 0.0554; 10k reads 0.0035 | 0.1489 |
| Variable: alert allowance | Three static metric series, email only | 0.3000 |
| Variable: egress allowance | 5 payable GB x 0.0654 | 0.3270 |
| **Total excluding VAT** | Fixed 28.9019; variable allowance 2.9412 | **31.8431** |
| **20% VAT assumption** | Actual treatment must be confirmed | **6.3686** |
| **Total including VAT** | Normal lab; allow GBP 40-45 operationally | **38.2117** |

Meter IDs: Linux B1 `4f4d0872-8289-4910-8369-70a8214fc1ef`;
Linux B2 `c90068d7-d718-46ce-b129-dca2099fd0f3`;
Basic SQL `a97bb631-35bd-47a7-ac4e-0c1ea52f1719`;
Analytics Logs ingestion `d664ef7a-c553-4b1c-a2ae-1a44ea5ed8ce`.
The ingestion meter has zero-price tier minimum 0 and payable rate 2.1653 at
tier minimum 5 GB. The estimate conservatively charges all 1 GB; do not assume
that a shared account's free allowance is available.

Storage catalogues contain multiple products with similarly named Hot ZRS
meters. Select ordinary Blob Storage, not ADLS iterative/file operations.
Baseline ordinary Hot ZRS rates are 0.018/GB-month and 0.0554/10k writes; use the
corresponding Blob read meter 0.0035/10k. No double counting of Insights plus
workspace ingestion. Exact General Block Blob v2 meter IDs: Hot ZRS stored
`3a569bf0-40eb-42eb-9905-2314559f852d`, writes/list-create
`52ee1b6a-fe1c-45ab-a429-a12362991a7e`, reads
`e0fc6c22-4a23-4014-9e12-cd403a33ed48`. Thirty-day
workspace retention adds no assumed excess
retention. Extra backup storage/LTR, restore databases, paid scheduler, SMS,
custom domains, CI and private networking are not included.
Health probes can add Blob property reads beyond the illustrative 10k; retain
the operating allowance and reconcile observed volume rather than treating
this quiet-lab estimate as a hard ceiling.

Reproduce and paginate the *public* query without Azure authentication:

```powershell
$filter = [uri]::EscapeDataString("armRegionName eq 'uksouth' and priceType eq 'Consumption' and serviceName eq 'Azure App Service'")
$url = "https://prices.azure.com/api/retail/prices?currencyCode=GBP&`$filter=$filter"
$items = @()
while ($url) {
    $page = Invoke-RestMethod $url
    $items += @($page.Items)
    $url = $page.NextPageLink
}
$items | Where-Object {
    $_.productName -eq 'Azure App Service Basic Plan - Linux' -and $_.skuName -in @('B1','B2')
} | Select-Object productName, meterName, meterId, unitOfMeasure, retailPrice, tierMinimumUnits, effectiveStartDate
```

Use separate SQL Database, Log Analytics, Blob Storage, Azure Monitor and
Bandwidth queries, preserving product, meter, unit and tier. App Service B1's
`armSkuName` is empty in this catalogue: filtering `armSkuName eq 'B1'` misses it.
Reference: [Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices).

## Headroom and scheduled/temporary charges

| Scenario | VAT-inclusive monthly estimate / incremental cost |
|---|---:|
| Normal B1/B1, 1 payable GB logs | GBP 38.21 |
| 3 payable GB logs | GBP 43.41 |
| Development B2 continuously | GBP 49.42; little headroom |
| B2 for 176 h, B1 for 554 h | GBP 40.92; no paid scheduling tool included |
| Production SQL S0 instead of Basic | GBP 49.30; not default |
| Another production B1 worker | GBP 50.04; still not zone resilient |
| Temporary S3 restore, 8 charged hours | About GBP 1.52 net / 1.82 gross, not a restore-time promise |

The preferred below-GBP-50 target is realistic for a quiet, bounded lab. GBP 100
is a desired ceiling, not guaranteed: logs, retained restores, traffic, extra
resources and pricing changes can exceed it. Do not use F1 by default merely to
achieve a cheaper headline; quotas/cold starts and no Always On weaken filming.

Stopping any/all web apps does NOT stop dedicated plan compute billing. Basic
SQL cannot pause. Serverless SQL can pause compute only when eligible inactivity
conditions are met; telemetry/polling can keep it awake and storage persists.
The serverless always-awake vCore estimate is much higher than this Basic DB.
Do not claim shutdown savings for fixed services.

## Tags, raw costs and shared allocation

Use native Azure Cost Management by resource group, service, resource and tag.
Raw production plan compute is GBP 9.855 net. Approved allocation:
CustomerPortal 40% = GBP 3.942; OrdersAPI 40% = GBP 3.942;
ReportingPortal 20% = GBP 1.971. Sum = GBP 9.855. These shares are a chargeback
policy, not metered per-app compute. Never add them to the raw plan charge.
Shared workspace/storage attribution needs a separately labelled allocation
policy if allocating further; no policy was silently chosen for those costs.

ARM tags do not inherit automatically from RGs. Cost Management inheritance is
usage-record processing for supported agreements/scopes (EA/MCA/MPA eligibility
must be checked); it is not resource tagging. Preserve resource overrides and
document unsupported/configuration child types. Historical costs are not
retroactively guaranteed to adopt new tags.

## Budgets and guardrails

Project-tag-filtered monthly budgets: GBP 41.67 net (approximately GBP 50 gross)
and GBP 83.33 net (approximately GBP 100 gross). Subscription budget service
uses billing currency; Bicep cannot force GBP. RG-filter examples: production 8,
development 18, shared 16 net. These overlap project totals, not extra charges.
Actual 50/80/100% and forecast 100% notifications go to supplied email contacts.
The project budget tag filter can omit unsupported/untagged charges; RG views
help reconcile coverage. Review both, not just the tag-filtered budget.

Budgets notify and do not enforce a spending cap. The workspace emergency
0.1 GB/day cap can overshoot and cause monitoring blindness; it is not a billing
limit. Application sampling/log verbosity and Blob lifecycle reduce normal
consumption before relying on the cap. Do not automate destructive shutdown.
References: [budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets),
[cost-data latency](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data).

## Genuine optimization before/after

Only opt into B2 if a genuine development workload justifies it. Record dated
SKU, metrics, actual costs and the reason before changing anything. B2 -> B1
steady-state compute saving: 730 x (0.0263 - 0.0135) = GBP 9.344 net /
GBP 11.2128 gross monthly. Measured bills depend on hours and latency.
Scheduled B2/B1 example saves GBP 8.51 gross versus continuous B2; not versus
the cheaper B1 baseline. No scheduler is deployed.

After separate resize approval, use only:
`Deploy.ps1 -Phase ResizeDevelopment -Profile demo -SubscriptionId ... -BillingCurrency GBP`.
Inspect what-if; preserve tags; avoid restarting/reconfiguring production
by redeploying root. Compare performance and costs after data arrives.
Retention/sampling/export lifecycle and Basic-vs-S0 are other *conditional*
opportunities. Do not manufacture load, anomalies, recommendations or savings.

## Turbo360 trial gates before filming

Start with separately approved read-only, least-privilege connection and automatic
actions OFF. Verify free entitlement, GBP/VAT display, scope, date range,
freshness and exact required roles. Turbo documentation differs on
Cost Management Reader versus Billing Reader and on historical import;
verify the tenant/trial path, do not guess broader permissions.

Verify cross-RG discovery (production apps on a shared-RG plan), Application/
Environment tags, cost groups, 40/40/20 shared-plan allocation and total
reconciliation. Document whether equal/percentage/metric strategies and suitable
metrics are actually available under the free licence. An allocation rule does
not split Azure's raw billing meter. Shared-parent rule limitations need checking.

Verify import/history behavior before recording; Azure PAYG cost data can take
up to 72 hours. Connect early after approval, use real dated exports and retain
source screenshots. Do not claim earlier history, actual costs or realized
savings that are absent. Native Azure/manual approved resizing remains usable
if free Turbo optimization/actions are unavailable. A full Stage 5 filming
runbook follows real Stage 4 results, not this local tranche.

Sources: [quick start](https://docs.turbo360.com/docs/cost-analyzer-quick-start-1),
[allocation](https://docs.turbo360.com/docs/cost-allocation-2),
[permissions](https://docs.turbo360.com/docs/permission-requirements-for-turbo360),
[optimization](https://docs.turbo360.com/docs/optimization-opportunities).
