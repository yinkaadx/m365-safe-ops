# Evidence: test run captured 6 September 2026

PowerShell 7.5.4 on Linux, no modules installed, no network, no tenant. The fake Graph is injected through the -Invoker parameter.

```
$ pwsh -NoProfile -File tests/run-tests.ps1
PASS retry honours Retry-After on 429 then succeeds
PASS gives up after MaxAttempts and rethrows
PASS client errors are not retried
PASS paging follows nextLink to the end
PASS report keeps only stale and never signed in devices
PASS report writes the CSV evidence
What if: Performing the operation "Set Content" on target "Path: /tmp/safeops-tests-d8cd2351017f48c59304ae89cb0cc76e/ev-whatif.jsonl".
What if: Performing the operation "Add Content" on target "Path: /tmp/safeops-tests-d8cd2351017f48c59304ae89cb0cc76e/ev-whatif.jsonl".
What if: Performing the operation "disable" on target "device DEV-a1 (a1)".
PASS WhatIf performs no writes
PASS disable writes before evidence then patches exactly the given ids
PASS rollback restores exactly the devices in the evidence file
PASS evidence lines are valid JSON with a header
PASS pilot assignment keeps existing assignments and adds the pilot group
PASS pilot assignment refuses an empty group id
PASS pilot assignment is a no op when the group is already assigned
PASS rollback reposts the original assignment set only
TESTRESULT: 14 passed, 0 failed
```

The three What if lines in the middle are the point of that check: under -WhatIf the module announces what it would do and the assertion proves no write reached the fake tenant.
