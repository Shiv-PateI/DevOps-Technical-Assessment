# Sample output

Audit logs from three runs of the identity sync, one after another, against the
mock data in `IdentitySync/Mocks`. All names and email addresses are fictional
and use the reserved `example.com` domain.

| File | Run | What it shows |
|---|---|---|
| `audit-sample-1-dry-run.jsonl` | `Invoke-IdentitySync.ps1` | A dry run: every worker's proposed action, with `mode` `DryRun` and `result` `Proposed`. Nothing changed. |
| `audit-sample-2-first-apply.jsonl` | `Invoke-IdentitySync.ps1 -Apply` | The first live run: identities created, emails written back, and each test case's outcome. |
| `audit-sample-3-second-apply.jsonl` | `Invoke-IdentitySync.ps1 -Apply` again | Re-running the same input: finished workers are `Skipped`, only unfinished stages run, nothing is done twice. |

## Format

JSON Lines: one JSON object per line, so the file can be read line by line,
searched with `Select-String`, and loaded into a log tool such as Azure Log
Analytics. Every line in a file has the same `correlationId`, a new GUID for
each run. Each line has an `event`:

| Event | Meaning |
|---|---|
| `RunStarted` | First line: the mode (`DryRun` or `Apply`) and how many HRIS records were read. |
| `Worker` | One line per employeeId: `proposedAction`, `reason`, `result`, `changeResult` (Update or Disable), `stage`, `stageResult` and `stageReason` (identity, mailbox and write-back), `entraObjectId`, `primarySmtpAddress`, `writeBackResult` and `retryCount`. |
| `IdentityNotInHRIS` | An Entra identity with no HRIS record, left unchanged. |
| `RunCompleted` | Last line: how many workers got each action and reached each stage. |
| `RunFailed` | Only if a run stops with an error, with the reason. |

No passwords, API tokens, names or other HRIS fields are written: a line holds
the employeeId and Entra object ID, which is enough to trace a worker.

## Test cases to look for

| employeeId | First live run | Second live run |
|---|---|---|
| E9014 | `Complete`, address `alex.clarke2@example.com` (assigned by Exchange, not the one requested) | `Skipped` |
| E9003 | Update `Done`, email `NoChange` | `NoChange`, `Skipped` |
| E9004 | Disable `Done` | `NothingDone` (already disabled) |
| E9011 | `IdentityFailed` after 3 retries (HTTP 503) | Tried again, `IdentityFailed` |
| E9012 | `MailboxPending` | Checked again, `MailboxPending` |
| E9015 | `WriteBackFailed` after 3 retries; identity created | Only the write-back retried |
| E9017 | `ManualReview`: the HRIS has a different address | `Skipped` |
| E8001 | `IdentityNotInHRIS`, left unchanged | Same |

## Reading a sample as a table

```powershell
Get-Content .\samples\audit-sample-2-first-apply.jsonl | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object event -eq 'Worker' |
    Format-Table employeeId, proposedAction, result, stage, retryCount, primarySmtpAddress
```

## Producing them again

The samples were made with `-Today 2026-11-04` and separate state and report
folders, so they do not touch the working state in `IdentitySync/State`. The
timestamps, correlation IDs and new Entra object IDs differ on every run.

```powershell
$state = "$env:TEMP\sample-state"
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1        -StatePath $state -ReportsPath "$env:TEMP\sample-1" -Today 2026-11-04
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply -StatePath $state -ReportsPath "$env:TEMP\sample-2" -Today 2026-11-04
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply -StatePath $state -ReportsPath "$env:TEMP\sample-3" -Today 2026-11-04
```
