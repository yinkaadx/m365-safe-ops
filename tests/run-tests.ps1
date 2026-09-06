# Test runner, no dependencies: plain pwsh, a fake Graph, defined pass and fail markers.
# Run: pwsh -NoProfile -File tests/run-tests.ps1
# Markers: one "PASS <name>" or "FAIL <name>: <detail>" line per check, then "TESTRESULT: X passed, Y failed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'SafeOps' 'SafeOps.psm1') -Force

$script:pass = 0; $script:fail = 0
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:pass++; Write-Host "PASS $Name" }
    catch { $script:fail++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function Assert-True($Cond, [string]$Because) { if (-not $Cond) { throw "expected true: $Because" } }
function Assert-Equal($Expected, $Actual, [string]$What) { if ("$Expected" -ne "$Actual") { throw "$What expected [$Expected] got [$Actual]" } }

function New-FakeGraph {
    # Routes requests to canned responses and records every call.
    param([hashtable]$Routes)
    $state = @{ calls = [System.Collections.Generic.List[object]]::new(); routes = $Routes }
    $invoker = {
        param($method, $uri, $body)
        $state.calls.Add(@{ method = $method; uri = $uri; body = $body })
        $keys = @($state.routes.Keys) | Sort-Object { $_.Length } -Descending  # most specific pattern wins
        foreach ($k in $keys) {
            $m, $pattern = $k.Split(' ', 2)
            if ($method -eq $m -and $uri -like $pattern) {
                $r = $state.routes[$k]
                if ($r -is [scriptblock]) { return & $r $method $uri $body }
                return $r
            }
        }
        throw (New-GraphError -StatusCode 404 -Message "no fake route for $method $uri")
    }.GetNewClosure()
    return @{ invoker = $invoker; state = $state }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("safeops-tests-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp | Out-Null

# ---------------------------------------------------------------- transport
Check 'retry honours Retry-After on 429 then succeeds' {
    $n = @{ count = 0 }
    $invoker = { param($m, $u, $b)
        $n.count++
        if ($n.count -lt 3) { throw (New-GraphError -StatusCode 429 -RetryAfterSeconds 0) }
        return @{ ok = $true }
    }.GetNewClosure()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-SafeGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/x' -Invoker $invoker -BaseDelaySeconds 0.01
    $sw.Stop()
    Assert-Equal 3 $n.count 'attempt count'
    Assert-True $r.ok 'final response returned'
}

Check 'gives up after MaxAttempts and rethrows' {
    $n = @{ count = 0 }
    $invoker = { param($m, $u, $b) $n.count++; throw (New-GraphError -StatusCode 503 -RetryAfterSeconds 0) }.GetNewClosure()
    $threw = $false
    try { Invoke-SafeGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/x' -Invoker $invoker -MaxAttempts 4 -BaseDelaySeconds 0.01 | Out-Null }
    catch { $threw = $true }
    Assert-True $threw 'exception rethrown'
    Assert-Equal 4 $n.count 'stopped at MaxAttempts'
}

Check 'client errors are not retried' {
    $n = @{ count = 0 }
    $invoker = { param($m, $u, $b) $n.count++; throw (New-GraphError -StatusCode 400) }.GetNewClosure()
    try { Invoke-SafeGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/x' -Invoker $invoker -BaseDelaySeconds 0.01 | Out-Null } catch {}
    Assert-Equal 1 $n.count 'exactly one attempt on 400'
}

Check 'paging follows nextLink to the end' {
    $fake = New-FakeGraph @{
        'GET *devices*skiptoken=p2*' = @{ value = @(@{ id = 'd3' }) }
        'GET *devices*'              = @{ value = @(@{ id = 'd1' }, @{ id = 'd2' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/devices?$skiptoken=p2' }
    }
    $all = Get-GraphPage -Uri 'https://graph.microsoft.com/v1.0/devices' -Invoker $fake.invoker
    Assert-Equal 3 $all.Count 'three devices across two pages'
}

# ---------------------------------------------------------------- stale device report
$old = (Get-Date).ToUniversalTime().AddDays(-400).ToString('o')
$fresh = (Get-Date).ToUniversalTime().AddDays(-3).ToString('o')
$deviceRoutes = @{
    'GET *v1.0/devices?*' = @{ value = @(
            @{ id = 'a1'; deviceId = 'x1'; displayName = 'OLD-LAPTOP'; operatingSystem = 'Windows'; accountEnabled = $true; approximateLastSignInDateTime = $old },
            @{ id = 'a2'; deviceId = 'x2'; displayName = 'NEW-LAPTOP'; operatingSystem = 'Windows'; accountEnabled = $true; approximateLastSignInDateTime = $fresh },
            @{ id = 'a3'; deviceId = 'x3'; displayName = 'GHOST-MAC'; operatingSystem = 'MacMDM'; accountEnabled = $true; approximateLastSignInDateTime = $null }
        ) }
}

Check 'report keeps only stale and never signed in devices' {
    $fake = New-FakeGraph $deviceRoutes
    $rep = @(Get-StaleDeviceReport -InactiveDays 180 -Invoker $fake.invoker)
    Assert-Equal 2 $rep.Count 'two stale devices'
    Assert-True ($rep.id -contains 'a1' -and $rep.id -contains 'a3') 'old and never signed in included'
    Assert-True (-not ($rep.id -contains 'a2')) 'active device excluded'
    Assert-True (($rep | Where-Object id -eq 'a3').neverSignedIn) 'never signed in flagged'
}

Check 'report writes the CSV evidence' {
    $fake = New-FakeGraph $deviceRoutes
    $csv = Join-Path $tmp 'stale.csv'
    Get-StaleDeviceReport -InactiveDays 180 -CsvPath $csv -Invoker $fake.invoker | Out-Null
    $rows = @(Import-Csv $csv)
    Assert-Equal 2 $rows.Count 'csv rows'
}

# ---------------------------------------------------------------- disable with WhatIf, evidence, rollback
function New-DisableFake {
    $store = @{ a1 = $true; a3 = $true }
    $fake = New-FakeGraph @{}
    $fake.state.routes['GET *v1.0/devices/*'] = { param($m, $u, $b)
        $id = ($u -split '/devices/')[1] -replace '\?.*$', ''
        return @{ id = $id; displayName = "DEV-$id"; accountEnabled = $store[$id] }
    }.GetNewClosure()
    $fake.state.routes['PATCH *v1.0/devices/*'] = { param($m, $u, $b)
        $id = ($u -split '/devices/')[1]
        $store[$id] = [bool]$b.accountEnabled
        return @{}
    }.GetNewClosure()
    return @{ fake = $fake; store = $store }
}

Check 'WhatIf performs no writes' {
    $d = New-DisableFake
    $ev = Join-Path $tmp 'ev-whatif.jsonl'
    Disable-StaleDevice -DeviceObjectId 'a1' -EvidencePath $ev -Invoker $d.fake.invoker -WhatIf | Out-Null
    $patches = @($d.fake.state.calls | Where-Object { $_.method -eq 'PATCH' })
    Assert-Equal 0 $patches.Count 'no PATCH under WhatIf'
    Assert-True $d.store.a1 'device still enabled'
}

Check 'disable writes before evidence then patches exactly the given ids' {
    $d = New-DisableFake
    $ev = Join-Path $tmp 'ev-disable.jsonl'
    $done = @(Disable-StaleDevice -DeviceObjectId 'a1', 'a3' -EvidencePath $ev -Invoker $d.fake.invoker -Confirm:$false)
    Assert-Equal 2 $done.Count 'both devices processed'
    Assert-True (-not $d.store.a1 -and -not $d.store.a3) 'both disabled in the fake tenant'
    $before = Read-Evidence -Path $ev -Kind before
    Assert-Equal 2 $before.Count 'two before records'
    Assert-True ($before[0].data.accountEnabled) 'before state captured as enabled'
    $patches = @($d.fake.state.calls | Where-Object { $_.method -eq 'PATCH' })
    Assert-Equal 2 $patches.Count 'exactly two PATCH calls'
}

Check 'rollback restores exactly the devices in the evidence file' {
    $d = New-DisableFake
    $ev = Join-Path $tmp 'ev-roll.jsonl'
    Disable-StaleDevice -DeviceObjectId 'a1' -EvidencePath $ev -Invoker $d.fake.invoker -Confirm:$false | Out-Null
    Assert-True (-not $d.store.a1) 'disabled first'
    $restored = @(Restore-DeviceState -EvidencePath $ev -Invoker $d.fake.invoker -Confirm:$false)
    Assert-Equal 1 $restored.Count 'one device restored'
    Assert-True $d.store.a1 'enabled again from evidence'
    Assert-True $d.store.a3 'untouched device stays untouched'
    $roll = Read-Evidence -Path $ev -Kind rollback
    Assert-Equal 1 $roll.Count 'rollback recorded'
}

Check 'evidence lines are valid JSON with a header' {
    $ev = Join-Path $tmp 'ev-parse.jsonl'
    New-EvidenceLog -Path $ev -Operation 'demo' | Out-Null
    Write-Evidence -Path $ev -Kind note -Data @{ hello = 'world' }
    $rows = Read-Evidence -Path $ev
    Assert-Equal 2 $rows.Count 'header plus one record'
    Assert-Equal 'header' $rows[0].kind 'header first'
    Assert-Equal 'world' $rows[1].data.hello 'payload round trips'
}

# ---------------------------------------------------------------- compliance policy pilot assignment
function New-PolicyFake {
    $state = @{ assignments = @(@{ id = 'as1'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'prod-group' } }) }
    $fake = New-FakeGraph @{}
    $fake.state.routes['GET *deviceCompliancePolicies/pol1/assignments*'] = { param($m, $u, $b) return @{ value = $state.assignments } }.GetNewClosure()
    $fake.state.routes['POST *deviceCompliancePolicies/pol1/assign*'] = { param($m, $u, $b)
        $state.assignments = @($b.assignments | ForEach-Object { @{ id = 'new'; target = $_.target } })
        return @{}
    }.GetNewClosure()
    return @{ fake = $fake; state = $state }
}

Check 'pilot assignment keeps existing assignments and adds the pilot group' {
    $p = New-PolicyFake
    $ev = Join-Path $tmp 'ev-pol.jsonl'
    $r = Add-CompliancePolicyPilotAssignment -PolicyId 'pol1' -PilotGroupId 'pilot-group' -EvidencePath $ev -Invoker $p.fake.invoker -Confirm:$false
    Assert-True $r 'assignment applied'
    Assert-Equal 2 $p.state.assignments.Count 'existing plus pilot'
    $groups = @($p.state.assignments | ForEach-Object { $_.target.groupId })
    Assert-True ($groups -contains 'prod-group' -and $groups -contains 'pilot-group') 'both groups present'
}

Check 'pilot assignment refuses an empty group id' {
    $p = New-PolicyFake
    $threw = $false
    try { Add-CompliancePolicyPilotAssignment -PolicyId 'pol1' -PilotGroupId '  ' -EvidencePath (Join-Path $tmp 'x.jsonl') -Invoker $p.fake.invoker -Confirm:$false | Out-Null }
    catch { $threw = $true }
    Assert-True $threw 'refused'
}

Check 'pilot assignment is a no op when the group is already assigned' {
    $p = New-PolicyFake
    $ev = Join-Path $tmp 'ev-pol-noop.jsonl'
    $r = Add-CompliancePolicyPilotAssignment -PolicyId 'pol1' -PilotGroupId 'prod-group' -EvidencePath $ev -Invoker $p.fake.invoker -Confirm:$false
    Assert-True (-not $r) 'reported no op'
    $posts = @($p.fake.state.calls | Where-Object { $_.method -eq 'POST' })
    Assert-Equal 0 $posts.Count 'no assign call'
}

Check 'rollback reposts the original assignment set only' {
    $p = New-PolicyFake
    $ev = Join-Path $tmp 'ev-pol-roll.jsonl'
    Add-CompliancePolicyPilotAssignment -PolicyId 'pol1' -PilotGroupId 'pilot-group' -EvidencePath $ev -Invoker $p.fake.invoker -Confirm:$false | Out-Null
    Assert-Equal 2 $p.state.assignments.Count 'pilot in place'
    Remove-CompliancePolicyPilotAssignment -EvidencePath $ev -Invoker $p.fake.invoker -Confirm:$false | Out-Null
    Assert-Equal 1 $p.state.assignments.Count 'back to original set'
    Assert-Equal 'prod-group' $p.state.assignments[0].target.groupId 'original group intact'
}

Remove-Item -Recurse -Force $tmp
Write-Host "TESTRESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
