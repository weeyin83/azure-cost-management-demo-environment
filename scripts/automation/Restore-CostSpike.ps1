#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$StateJson,
    [ValidateSet('Restore', 'Verify')][string]$Mode = 'Restore'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SpikeState {
    param([hashtable]$State)
    $id = [guid]::Empty
    if (-not [guid]::TryParse($State.runId, [ref]$id) -or $State.project -ne 'ContosoFinOpsDemo' -or
        @($State.plans).Count -ne 2) { throw 'Invalid cost-spike state.' }
    $groups = @()
    foreach ($plan in $State.plans) {
        if ($plan.id -notmatch "^/subscriptions/$($State.subscriptionId)/resourceGroups/(rg-finops-development|rg-finops-shared)/providers/Microsoft.Web/serverfarms/[^/]+$" -or
            $plan.baselineSku -ne 'B1' -or $plan.baselineCapacity -ne 1 -or
            $plan.targetSku -ne 'S3' -or $plan.targetCapacity -ne 1) {
            throw 'State must identify exactly the approved B1-to-S3 plans.'
        }
        $groups += $Matches[1]
    }
    if (@($groups | Sort-Object -Unique).Count -ne 2) { throw 'State must contain one plan in each approved group.' }
    if (-not [guid]::TryParse($State.subscriptionId, [ref]$id)) { throw 'Invalid state subscription.' }
}

function Invoke-SpikeManagedArm {
    param([string]$Method, [string]$ResourceId, [hashtable]$Body)
    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or
        [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) { throw 'Automation managed identity is unavailable.' }
    $token = Invoke-RestMethod -Method Get -Uri "$($env:IDENTITY_ENDPOINT)?resource=https%3A%2F%2Fmanagement.azure.com%2F&api-version=2019-08-01" `
        -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'true' }
    if ([string]::IsNullOrWhiteSpace($token.access_token)) { throw 'Managed-identity token response contained no access token.' }
    $arguments = @{
        Method = $Method
        Uri = "https://management.azure.com${ResourceId}?api-version=2025-03-01"
        Headers = @{ Authorization = "Bearer $($token.access_token)" }
        TimeoutSec = 90
    }
    if ($null -ne $Body) {
        $arguments.Body = $Body | ConvertTo-Json -Depth 30 -Compress
        $arguments.ContentType = 'application/json'
    }
    Invoke-RestMethod @arguments | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
}

function Invoke-SpikeRestoration {
    param(
        [hashtable]$State,
        [scriptblock]$Request = ${function:Invoke-SpikeManagedArm},
        [switch]$VerifyOnly
    )
    Assert-SpikeState $State
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($plan in $State.plans) {
        try {
            $restored = $false
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                try {
                    $current = & $Request 'GET' $plan.id $null
                    if ($current.tags.Project -ne $State.project -or -not $current.properties.reserved) {
                        throw "Project/Linux invariant failed: $($plan.id)"
                    }
                    $baseline = $current.sku.name -eq 'B1' -and $current.sku.capacity -eq 1 -and
                        $current.properties.provisioningState -eq 'Succeeded'
                    $owner = $current.tags['CostSpikeRun']
                    if ($VerifyOnly) {
                        if (-not $baseline -or $owner) { throw 'Verification requires an unowned B1/one-worker baseline.' }
                        $restored = $true
                        break
                    }
                    if ($baseline -and -not $owner) {
                        $restored = $true
                        break
                    }
                    if ($owner -ne $State.runId -or (-not $baseline -and
                        ($current.sku.name -ne 'S3' -or $current.sku.capacity -ne 1))) {
                        throw "Unexpected intervening resize/owner; refusing to overwrite $($plan.id). Restore manually after review."
                    }
                    if (-not $baseline) {
                        [void](& $Request 'PATCH' $plan.id @{
                            sku = @{ name = 'B1'; tier = 'Basic'; capacity = 1 }
                        })
                    }
                    for ($poll = 0; $poll -lt 30; $poll++) {
                        $observed = & $Request 'GET' $plan.id $null
                        if ($observed.sku.name -eq 'B1' -and $observed.sku.capacity -eq 1 -and
                            $observed.tags['CostSpikeRun'] -eq $State.runId -and $observed.properties.provisioningState -eq 'Succeeded') {
                            $restored = $true
                            break
                        }
                        Start-Sleep -Seconds 10
                    }
                    if (-not $restored) { throw "Restoration did not complete: $($plan.id)" }
                    $tags = @{} + $observed.tags
                    $tags.Remove('CostSpikeRun')
                    [void](& $Request 'PATCH' $plan.id @{ tags = $tags })
                    $observed = & $Request 'GET' $plan.id $null
                    if ($observed.sku.name -ne 'B1' -or $observed.sku.capacity -ne 1 -or $observed.tags['CostSpikeRun']) {
                        throw "Baseline/run-owner removal could not be verified: $($plan.id)"
                    }
                    break
                } catch {
                    if ($attempt -eq 2) { throw }
                    Write-Warning "Restore attempt failed for $($plan.id): $($_.Exception.Message). Retrying."
                    Start-Sleep -Seconds 20
                }
            }
            if (-not $restored) { throw "No verified baseline: $($plan.id)" }
            Write-Output "Verified B1/one worker: $($plan.id)"
        } catch {
            $failures.Add("$($plan.id): $($_.Exception.Message)")
        }
    }
    if ($failures.Count) { throw "Cost-spike recovery failed; other plans were still attempted: $($failures -join '; ')" }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($StateJson)) { throw 'StateJson is required.' }
    $state = $StateJson | ConvertFrom-Json -AsHashtable
    Invoke-SpikeRestoration -State $state -VerifyOnly:($Mode -eq 'Verify')
}
