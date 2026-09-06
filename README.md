# SafeOps: safe Microsoft Graph change automation

Production changes in Microsoft 365 and Entra fail in a predictable way: a script that worked in the console gets pointed at the whole tenant, nothing recorded what state looked like before, and rollback means memory. This module encodes the discipline that prevents that, as working PowerShell you can read in ten minutes.

Every change here follows one pattern:

1. **Pilot scope is explicit.** A change function takes the exact object ids or one pilot group id. Nothing discovers its own targets, and the compliance assignment function refuses to target everyone.
2. **`-WhatIf` is honoured everywhere.** All change functions use `SupportsShouldProcess` with high confirm impact, so a dry run is the default posture.
3. **Evidence before change.** The state of every object is written to a JSON lines evidence file before it is touched, and again after. The evidence file is the audit trail a client can keep.
4. **Rollback works only from evidence.** The restore functions read the before records and put back exactly what was recorded, so rollback can never touch an object the change run did not touch.
5. **Throttling is respected.** One transport function talks to Graph: it retries 429 and transient 5xx, honours `Retry-After` when the service sends one, backs off exponentially otherwise, and never retries client errors.

## What is included

| Function | What it does |
| --- | --- |
| `Invoke-SafeGraphRequest` | The single Graph transport: retry, backoff, `Retry-After`, no retry on 4xx |
| `Get-GraphPage` | Follows `@odata.nextLink` to the end of a collection |
| `New-EvidenceLog`, `Write-Evidence`, `Read-Evidence` | JSON lines evidence file: header, before, after, rollback, note records |
| `Get-StaleDeviceReport` | Read only: Entra devices inactive past N days or never signed in, to objects and CSV |
| `Disable-StaleDevice` | Disables exactly the ids a person approved from the report, evidence first, `-WhatIf` honoured |
| `Restore-DeviceState` | Rollback: re enables from the evidence file only |
| `Add-CompliancePolicyPilotAssignment` | Assigns an Intune compliance policy to one pilot group while preserving every existing assignment (the Graph `assign` action replaces the whole set, which is exactly how accidental tenant wide rollouts happen) |
| `Remove-CompliancePolicyPilotAssignment` | Rollback: reposts the original assignment set from evidence |

## Run the tests

No dependencies beyond PowerShell 7. The suite runs against a fake Graph injected through `-Invoker`, so it needs no tenant, no credentials and no network:

```
pwsh -NoProfile -File tests/run-tests.ps1
```

Fourteen checks with defined pass and fail markers: retry and backoff behaviour, paging, the stale filter, CSV evidence, `-WhatIf` performing no writes, before evidence preceding every change, rollback restoring only recorded objects, assignment merge preserving existing targets, the refusal of an empty pilot group, and the no op when the pilot group is already assigned. `docs/evidence.md` holds a captured run.

## Run it against a tenant

```powershell
Install-Module Microsoft.Graph.Authentication
Connect-MgGraph -Scopes "Device.Read.All"                       # report only
Import-Module ./SafeOps/SafeOps.psm1

# 1. Evidence first: what would we touch
Get-StaleDeviceReport -InactiveDays 180 -CsvPath stale.csv

# 2. A person reviews the CSV and picks the pilot ids, then a dry run
Disable-StaleDevice -DeviceObjectId "id1","id2" -EvidencePath run1.jsonl -WhatIf

# 3. The real change (needs Device.ReadWrite.All), evidence captured either side
Disable-StaleDevice -DeviceObjectId "id1","id2" -EvidencePath run1.jsonl

# 4. If anything is wrong, rollback from the evidence file
Restore-DeviceState -EvidencePath run1.jsonl
```

The Intune pair works the same way with `DeviceManagementConfiguration.ReadWrite.All`: assign the policy to the pilot group, watch compliance for the pilot, then either widen deliberately or repost the original assignment set from evidence.

Least privilege applies throughout: connect with the smallest scope the step needs, report with read scopes, and grant write scopes only for the change window. In a partner context, run under GDAP roles scoped to the task rather than standing admin.

Everything in this repository is sanitized demonstration code: synthetic ids, a fake Graph in tests, no tenant identifiers and no client data.
