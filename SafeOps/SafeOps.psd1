@{
    RootModule        = 'SafeOps.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7f6b7c2e-4a41-4d2e-9d1a-3f0c2b7e5a10'
    Author            = 'Yinka Aderibigbe'
    Description       = 'Safe Microsoft Graph change automation: pilot scopes, WhatIf, evidence files, rollback from evidence, throttling discipline.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('New-GraphError','Invoke-SafeGraphRequest','Get-GraphPage','New-EvidenceLog','Write-Evidence','Read-Evidence','Get-StaleDeviceReport','Disable-StaleDevice','Restore-DeviceState','Add-CompliancePolicyPilotAssignment','Remove-CompliancePolicyPilotAssignment')
}
