# SafeOps: safe Microsoft Graph change automation.
# Every change follows the same pattern: pilot scope stated explicitly, WhatIf honoured,
# before state captured to an evidence file, change applied, after state captured,
# and a rollback function that works only from the evidence file.
# Functions take -Invoker so tests run against a fake Graph; production omits it and
# uses Invoke-MgGraphRequest from the Microsoft.Graph.Authentication module.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- transport

function New-GraphError {
    # Builds a throwable error carrying an HTTP status, used by tests and by callers
    # that wrap other transports. Real Graph SDK exceptions are parsed in the catch below.
    param([Parameter(Mandatory)][int]$StatusCode, [int]$RetryAfterSeconds, [string]$Message = "Graph request failed")
    $ex = [System.Exception]::new("$Message (status $StatusCode)")
    $ex.Data['StatusCode'] = $StatusCode
    if ($PSBoundParameters.ContainsKey('RetryAfterSeconds')) { $ex.Data['RetryAfter'] = $RetryAfterSeconds }
    return $ex
}

function Get-GraphErrorStatus {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.Data -and $ex.Data.Contains('StatusCode')) { return [int]$ex.Data['StatusCode'] }
        if ($ex.PSObject.Properties['Response'] -and $ex.Response -and $ex.Response.PSObject.Properties['StatusCode']) {
            return [int]$ex.Response.StatusCode
        }
        $ex = $ex.InnerException
    }
    return $null
}

function Invoke-SafeGraphRequest {
    <#
      Graph call with throttling discipline: retries 429 and transient 5xx,
      honours Retry-After when the service sends one, exponential backoff otherwise,
      never retries client errors. This is the only function that talks to Graph.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [int]$MaxAttempts = 5,
        [double]$BaseDelaySeconds = 2,
        [scriptblock]$Invoker
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($Invoker) { return & $Invoker $Method $Uri $Body }
            $params = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $params['Body'] = ($Body | ConvertTo-Json -Depth 20)
                $params['ContentType'] = 'application/json'
            }
            return Invoke-MgGraphRequest @params
        }
        catch {
            $status = Get-GraphErrorStatus $_
            $retryable = $status -in 429, 502, 503, 504
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }
            $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1)
            if ($_.Exception.Data -and $_.Exception.Data.Contains('RetryAfter')) { $delay = [double]$_.Exception.Data['RetryAfter'] }
            Write-Verbose "attempt $attempt got status $status, waiting $delay s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GraphPage {
    # Follows @odata.nextLink until the collection is complete.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [scriptblock]$Invoker, [int]$MaxAttempts = 5, [double]$BaseDelaySeconds = 2)
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-SafeGraphRequest -Method GET -Uri $next -Invoker $Invoker -MaxAttempts $MaxAttempts -BaseDelaySeconds $BaseDelaySeconds
        $values = if ($page -is [System.Collections.IDictionary]) { $page['value'] } elseif ($page.PSObject.Properties['value']) { $page.value } else { $null }
        foreach ($v in @($values)) { if ($null -ne $v) { $all.Add($v) } }
        $next = if ($page -is [System.Collections.IDictionary]) { $page['@odata.nextLink'] } elseif ($page.PSObject.Properties['@odata.nextLink']) { $page.'@odata.nextLink' } else { $null }
    }
    return $all
}

# ---------------------------------------------------------------- evidence

function New-EvidenceLog {
    <# Creates a JSON lines evidence file. Every change run starts here; rollback reads it back. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Operation)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $header = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); kind = 'header'; operation = $Operation; host = [Environment]::MachineName }
    ($header | ConvertTo-Json -Compress) | Set-Content -Path $Path -Encoding utf8
    return $Path
}

function Write-Evidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('before', 'after', 'rollback', 'note')][string]$Kind, [Parameter(Mandatory)]$Data)
    $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); kind = $Kind; data = $Data }
    ($rec | ConvertTo-Json -Compress -Depth 20) | Add-Content -Path $Path -Encoding utf8
}

function Read-Evidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Kind)
    $rows = Get-Content -Path $Path -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
    if ($Kind) { $rows = $rows | Where-Object { $_.kind -eq $Kind } }
    return @($rows)
}

# ---------------------------------------------------------------- stale devices (Entra)

function Get-StaleDeviceReport {
    <#
      Read only. Lists Entra devices whose approximate last sign in is older than
      InactiveDays, or that never signed in. Emits objects and an optional CSV,
      which is the evidence a disable decision is made from.
      Production scope needed: Device.Read.All.
    #>
    [CmdletBinding()]
    param([int]$InactiveDays = 180, [string]$CsvPath, [scriptblock]$Invoker)
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $InactiveDays)
    $uri = "https://graph.microsoft.com/v1.0/devices?`$select=id,deviceId,displayName,operatingSystem,accountEnabled,approximateLastSignInDateTime"
    $devices = Get-GraphPage -Uri $uri -Invoker $Invoker
    $stale = foreach ($d in $devices) {
        $last = $null
        if ($d.approximateLastSignInDateTime) { $last = [datetime]$d.approximateLastSignInDateTime }
        if ($null -eq $last -or $last -lt $cutoff) {
            [pscustomobject]@{
                id = $d.id; deviceId = $d.deviceId; displayName = $d.displayName
                operatingSystem = $d.operatingSystem; accountEnabled = $d.accountEnabled
                lastSignIn = if ($last) { $last.ToString('o') } else { $null }
                neverSignedIn = ($null -eq $last)
            }
        }
    }
    $stale = @($stale)
    if ($CsvPath) { $stale | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8 }
    return $stale
}

function Disable-StaleDevice {
    <#
      Disables exactly the device object ids passed in, never a discovered set:
      the pilot scope is the explicit list, reviewed by a person from the report.
      Captures accountEnabled before and after into the evidence file.
      Honours -WhatIf. Production scope needed: Device.ReadWrite.All (or the
      Cloud Device Administrator role for enable and disable).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string[]]$DeviceObjectId,
        [Parameter(Mandatory)][string]$EvidencePath,
        [scriptblock]$Invoker
    )
    if (-not (Test-Path $EvidencePath)) { New-EvidenceLog -Path $EvidencePath -Operation 'disable-stale-devices' | Out-Null }
    $done = @()
    foreach ($id in $DeviceObjectId) {
        if ([string]::IsNullOrWhiteSpace($id)) { throw "empty device object id" }
        $current = Invoke-SafeGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices/$id`?`$select=id,displayName,accountEnabled" -Invoker $Invoker
        Write-Evidence -Path $EvidencePath -Kind before -Data @{ id = $current.id; displayName = $current.displayName; accountEnabled = $current.accountEnabled }
        if ($PSCmdlet.ShouldProcess("device $($current.displayName) ($id)", "disable")) {
            Invoke-SafeGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/devices/$id" -Body @{ accountEnabled = $false } -Invoker $Invoker | Out-Null
            Write-Evidence -Path $EvidencePath -Kind after -Data @{ id = $id; accountEnabled = $false }
            $done += $id
        }
    }
    return $done
}

function Restore-DeviceState {
    <#
      Rollback. Reads the before records from the evidence file and puts every
      device back to the accountEnabled value it had. Works only from evidence,
      so it can never touch a device the change run did not touch.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$EvidencePath, [scriptblock]$Invoker)
    $before = Read-Evidence -Path $EvidencePath -Kind before
    $restored = @()
    foreach ($rec in $before) {
        $id = $rec.data.id
        if ($PSCmdlet.ShouldProcess("device $id", "restore accountEnabled=$($rec.data.accountEnabled)")) {
            Invoke-SafeGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/devices/$id" -Body @{ accountEnabled = $rec.data.accountEnabled } -Invoker $Invoker | Out-Null
            Write-Evidence -Path $EvidencePath -Kind rollback -Data @{ id = $id; accountEnabled = $rec.data.accountEnabled }
            $restored += $id
        }
    }
    return $restored
}

# ---------------------------------------------------------------- Intune compliance policy pilot assignment

function Add-CompliancePolicyPilotAssignment {
    <#
      Assigns an Intune device compliance policy to one pilot group, preserving
      every existing assignment (the Graph assign action replaces the whole set,
      which is exactly how accidental production rollouts happen). Refuses to
      target everyone. Production scope needed: DeviceManagementConfiguration.ReadWrite.All.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$PolicyId,
        [Parameter(Mandatory)][string]$PilotGroupId,
        [Parameter(Mandatory)][string]$EvidencePath,
        [scriptblock]$Invoker
    )
    if ([string]::IsNullOrWhiteSpace($PilotGroupId)) { throw "pilot group id is required; this function never targets all devices or all users" }
    $base = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$PolicyId"
    $existing = @((Invoke-SafeGraphRequest -Method GET -Uri "$base/assignments" -Invoker $Invoker).value)
    if (-not (Test-Path $EvidencePath)) { New-EvidenceLog -Path $EvidencePath -Operation 'compliance-pilot-assignment' | Out-Null }
    Write-Evidence -Path $EvidencePath -Kind before -Data @{ policyId = $PolicyId; assignments = $existing }
    foreach ($a in $existing) {
        if ($a.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget' -and $a.target.groupId -eq $PilotGroupId) {
            Write-Evidence -Path $EvidencePath -Kind note -Data @{ message = "pilot group already assigned; nothing to do" }
            return $false
        }
    }
    $targets = @()
    foreach ($a in $existing) { $targets += @{ target = $a.target } }
    $targets += @{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $PilotGroupId } }
    if ($PSCmdlet.ShouldProcess("compliance policy $PolicyId", "assign pilot group $PilotGroupId keeping $($existing.Count) existing assignment(s)")) {
        Invoke-SafeGraphRequest -Method POST -Uri "$base/assign" -Body @{ assignments = $targets } -Invoker $Invoker | Out-Null
        Write-Evidence -Path $EvidencePath -Kind after -Data @{ policyId = $PolicyId; assignmentCount = $targets.Count; pilotGroupId = $PilotGroupId }
        return $true
    }
    return $false
}

function Remove-CompliancePolicyPilotAssignment {
    <#
      Rollback for the pilot assignment: reads the before record and reposts
      exactly that assignment set, which removes the pilot group and nothing else.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$EvidencePath, [scriptblock]$Invoker)
    $before = Read-Evidence -Path $EvidencePath -Kind before | Select-Object -Last 1
    if (-not $before) { throw "no before record in $EvidencePath" }
    $policyId = $before.data.policyId
    $targets = @()
    foreach ($a in @($before.data.assignments)) {
        $t = @{ '@odata.type' = $a.target.'@odata.type' }
        foreach ($p in $a.target.PSObject.Properties) { if ($p.Name -ne '@odata.type') { $t[$p.Name] = $p.Value } }
        $targets += @{ target = $t }
    }
    if ($PSCmdlet.ShouldProcess("compliance policy $policyId", "restore original $($targets.Count) assignment(s)")) {
        Invoke-SafeGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$policyId/assign" -Body @{ assignments = $targets } -Invoker $Invoker | Out-Null
        Write-Evidence -Path $EvidencePath -Kind rollback -Data @{ policyId = $policyId; assignmentCount = $targets.Count }
        return $true
    }
    return $false
}

Export-ModuleMember -Function New-GraphError, Invoke-SafeGraphRequest, Get-GraphPage, New-EvidenceLog, Write-Evidence, Read-Evidence, Get-StaleDeviceReport, Disable-StaleDevice, Restore-DeviceState, Add-CompliancePolicyPilotAssignment, Remove-CompliancePolicyPilotAssignment
