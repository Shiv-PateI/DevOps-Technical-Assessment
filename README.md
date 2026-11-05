# Safe identity automation: HRIS to Entra ID, with email write-back

A PowerShell command-line tool that keeps Entra ID identities in line with an
HRIS (the trusted source of worker data), and writes each joiner's confirmed
email address back to the HRIS once their Exchange Online mailbox exists.

For each worker record it:

1. **Validates** the record and rejects anything that cannot be handled safely.
2. **Decides** one action, matching on `employeeId` only: `Create`, `Update`,
   `Disable`, `NoChange` or `ManualReview`.
3. With `-Apply`, **acts** on it through three separate, resumable stages:
   identity ready, mailbox ready, and email written back to the HRIS.
4. **Audits** everything to a structured JSON Lines log with a correlation ID.

It runs entirely against mocks of Microsoft Graph, Exchange Online and the
HRIS API. No live tenant, real personal data or credentials are used.

[![CI](https://github.com/Shiv-PateI/DevOps-Technical-Assessment/actions/workflows/ci.yml/badge.svg)](https://github.com/Shiv-PateI/DevOps-Technical-Assessment/actions/workflows/ci.yml)

## Contents

- [Quick start](#quick-start)
- [How to run it](#how-to-run-it)
- [Running the tests](#running-the-tests)
- [Repository layout](#repository-layout)
- [How it works](#how-it-works)
- [Design decisions](#design-decisions)
- [Assumptions](#assumptions)
- [Known limitations](#known-limitations)
- [What I would change for production](#what-i-would-change-for-production)
- [AI-assisted development](#ai-assisted-development)
- Further documents:
  [sequence diagram](docs/sequence-diagram.md) ·
  [threat and failure note](docs/threat-and-failure-note.md) ·
  [Azure design](docs/azure-design.md) ·
  [sample output](samples/README.md)

## Quick start

Requires Windows PowerShell 5.1 or PowerShell 7, and Pester 5 or later for the
tests. From the repository root:

```powershell
# Dry run: shows the decision for every worker and changes nothing.
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1

# Make the changes, starting from the mock files.
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply -ResetState

# Run it again: finished workers are skipped and unfinished stages resume.
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 -Apply
```

If scripts are blocked by the execution policy, allow them for the current
window only with `Set-ExecutionPolicy -Scope Process Bypass`.

## How to run it

```powershell
.\IdentitySync\Scripts\Invoke-IdentitySync.ps1 [-Apply] [-ResetState] [-Today <date>]
    [-WorkersPath <file>] [-IdentitiesPath <file>] [-BehaviourPath <file>]
    [-StatePath <folder>] [-ReportsPath <folder>]
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Apply` | off | Make changes. Without it the run is a dry run that changes nothing. |
| `-ResetState` | off | Delete the sync state and saved mock data first, so the run starts from the mock files. Audit logs are kept. |
| `-Today` | today | The date the rules treat as today, for start and end dates. |
| `-WorkersPath` | `IdentitySync/Mocks/HRIS-Workers.json` | The HRIS input: a JSON array of worker records. |
| `-IdentitiesPath` | `IdentitySync/Mocks/Entra-Identities.json` | The Entra users the mock tenant starts with. |
| `-BehaviourPath` | `IdentitySync/Mocks/mock-behaviour.json` | Which employeeIds the mocks fail for, and how slowly mailboxes appear. |
| `-StatePath` | `IdentitySync/State` | Where the sync state is kept (git-ignored). |
| `-ReportsPath` | `IdentitySync/Reports` | Where audit logs are written (git-ignored). |

The HRIS API token is read from the `IDENTITYSYNC_HRIS_TOKEN` environment
variable, never from a file or the command line, and is never printed or saved.
Without it, the mock's own token is used.

### Input

A JSON array of worker records in this shape:

```json
[
  {
    "employeeId": "E1042",
    "status": "Active",
    "firstName": "Alex",
    "lastName": "Smith",
    "department": "Quality",
    "managerEmployeeId": "E1008",
    "startDate": "2026-11-02",
    "endDate": null,
    "email": null
  }
]
```

[`IdentitySync/Mocks/HRIS-Workers.json`](IdentitySync/Mocks/HRIS-Workers.json)
holds 25 fictional records, including one or two for each test case in the
brief (the `E9xxx` IDs).

### Output

- **Terminal**: one block per worker, showing the decision, the HRIS record
  next to the Entra account (differences highlighted), every call made, any
  retries, and the result; then a summary.
- **Audit log**: `IdentitySync/Reports/audit-<UTC time>-<correlation ID>.jsonl`,
  one JSON line per event. See [sample output](samples/README.md) for real
  examples from a dry run and two live runs.
- **Sync state**: `IdentitySync/State/sync-state.json`, the stage each worker
  has reached, so a later run can carry on.

## Running the tests

```powershell
Import-Module Pester -MinimumVersion 5.0   # Windows also ships Pester 3.4, which cannot run these tests
Invoke-Pester ./Tests -Output Detailed
```

170 tests across five files:

| File | Covers |
|---|---|
| `IdentitySync.Tests.ps1` | Validation, the decision rules, duplicates, matching by employeeId |
| `IdentitySync.Mocks.Tests.ps1` | The Graph, Exchange and HRIS mocks behave like the real services |
| `IdentitySync.Pipeline.Tests.ps1` | The three stages, restarts, a lost state file, re-runs, the disable limit |
| `IdentitySync.Retry.Tests.ps1` | Retry and back-off: transient vs permanent failures, waits, Retry-After |
| `IdentitySync.Audit.Tests.ps1` | The audit log, including full live and dry runs |

`Tests/Invoke-TestWalkthrough.ps1` runs the manual test steps end to end with
automatic checks (67 of them) and restores the mock files afterwards:

```powershell
.\Tests\Invoke-TestWalkthrough.ps1            # pauses between steps
.\Tests\Invoke-TestWalkthrough.ps1 -NoPause
```

Linting, as CI runs it:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

**CI** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs
PSScriptAnalyzer and all the tests on Windows PowerShell 5.1 and PowerShell 7 on
every push and pull request, with pinned tool versions and read-only
permissions.

## Repository layout

```
IdentitySync/
  Scripts/Invoke-IdentitySync.ps1   the entry point
  Modules/
    IdentitySync.psm1               validation and decision rules (no I/O)
    IdentitySync.Pipeline.psm1      applying decisions: stages, sync state
    IdentitySync.Retry.psm1         retry with exponential back-off
    IdentitySync.Audit.psm1         the JSON Lines audit log
    IdentitySync.Mocks.psm1         mock Graph, Exchange Online and HRIS
    IdentitySync.Files.psm1         reading and writing JSON safely
    IdentitySync.Display.psm1       everything printed to the terminal
  Mocks/                            mock data and behaviour
  State/  Reports/                  created at run time, git-ignored
Tests/                              Pester tests and the walkthrough script
samples/                            sample audit logs
docs/                               sequence diagram, threat note, Azure design
infra/main.bicep                    Azure resources for running it
```

## How it works

### Decision rules

Checked in order; the first match wins. All matching is on `employeeId`, with
exact case, never on name or email.

| # | Situation | Decision |
|---|---|---|
| 1 | Record fails validation (missing field, bad `employeeId`, status other than exactly `Active` or `Inactive`, date not `yyyy-MM-dd`, end before start, leaver without an end date, own manager) | `ManualReview`, listing every problem |
| 2 | More than one HRIS record with the same `employeeId`, even if identical | `ManualReview`: HR must remove the duplicate |
| 3 | More than one Entra identity with the same `employeeId` | `ManualReview`: never guess which is right |
| 4 | Status and end date contradict each other (`Active` but left, `Inactive` but not yet left) | `ManualReview` |
| 5 | No identity, leaver | `NoChange` |
| 6 | No identity, joiner | `Create`, enabled straight away, even before the start date |
| 7 | Identity exists, leaver (`Inactive` **and** end date passed), still enabled | `Disable` |
| 8 | Identity exists, leaver, already disabled | `NoChange` |
| 9 | Identity exists, active, department or manager differs | `Update` of only the attributes that differ |
| 10 | Identity exists and matches | `NoChange` |

An Entra identity with no HRIS record is reported and **never disabled**: a
worker missing from one input file is not proof that they have left.

### The three stages

With `-Apply`, every active worker goes through three stages. Each is saved to
the sync state as soon as it completes, so a later run (or a restart) carries
on from the last stage reached and never repeats one.

```
Pending -> IdentityReady -> MailboxReady -> Complete
              |                  |               |
        IdentityFailed    MailboxPending   WriteBackFailed     (retried next run)
                                 |
                          MailboxTimeout   ManualReview        (stop: a person decides)
```

1. **Identity ready.** Look up the `employeeId` in Entra with `Get-MgUser`; if
   there is no identity and the decision is `Create`, create one with
   `New-MgUser` and set the manager.
2. **Mailbox ready.** `Get-EXOMailbox` until the mailbox exists, then take its
   `PrimarySmtpAddress`: the address Exchange assigned, which can differ from
   the one requested. At most three checks per run; after 24 hours without a
   mailbox the worker stops at `MailboxTimeout`.
3. **Written back.** Send that address to the HRIS for the worker with the same
   `employeeId`, with an idempotency key. If the HRIS already has it:
   `NoChange`. If it has a different address: `ManualReview`, never overwritten.

Updates and disables to existing identities are applied before the stages.

The [sequence diagram](docs/sequence-diagram.md) shows the full flow, with
retries and reconciliation across runs.

### Failures and retries

- **Within a run**, every call to Graph, Exchange and the HRIS is retried on
  `429`, `502`, `503` or `504`: up to 4 attempts, waiting 2, 4 then 8 seconds
  (plus jitter), honouring `Retry-After`. Other failures are not retried.
- **Across runs**, a stage that still fails is recorded (`IdentityFailed`,
  `MailboxPending`, `WriteBackFailed`) and only that stage is tried again next
  time.

### Audit log

One JSON Lines file per run, dry runs included, with the run's correlation ID on
every line: `RunStarted`, one `Worker` line per `employeeId`, one
`IdentityNotInHRIS` line per identity left alone, and `RunCompleted` (or
`RunFailed`). A `Worker` line holds the `employeeId`, proposed action, reason,
result, Entra object ID, confirmed primary SMTP address, write-back result and
retry count. No passwords, tokens, names or other HRIS fields are written.

## Design decisions

- **Decide first, then act.** The rules in `IdentitySync.psm1` take data in and
  return a decision; they make no calls and print nothing. That keeps them easy
  to test and makes the dry run safe by construction: it is the same decision
  code with the acting step left out.
- **Dry run by default.** Nothing changes without `-Apply`. Every dry run is
  audited, so there is a record of what *would* have happened.
- **`employeeId` is the only key.** Names collide (the mock data has three Alex
  Clarkes) and email addresses change. Matching is exact and case-sensitive,
  and `e1042` is rejected rather than treated as `E1042`.
- **Two signals before a disable.** A leaver is disabled only when the status
  is `Inactive` *and* the end date has passed. Any contradiction goes to a
  person. Disable never deletes.
- **A limit on disables.** If more than five disables are planned in one run,
  none are applied: a sudden wave of leavers is more likely a bad export than
  real departures.
- **Updates change department and manager only.** First and last names are set
  when an identity is created but not changed afterwards, because a rename can
  change sign-in names and addresses and should be a deliberate act.
- **Duplicates go to a person.** Two HRIS records with one `employeeId` go to
  `ManualReview` even when identical, because the HRIS should hold one record
  per worker. Two Entra identities with one `employeeId` are never guessed at.
- **Joiners get an enabled account straight away,** so it is ready for their
  first day.
- **The confirmed address comes from Exchange, never from the request.** The
  sync waits for `Get-EXOMailbox` and writes back its `PrimarySmtpAddress`.
- **A different address in the HRIS is never overwritten.** There is no
  authoritative-update rule: a conflict is `ManualReview`, so the HRIS team
  decides which address is right.
- **Three stages, each saved.** Identity, mailbox and write-back are separate
  states in the sync state file, so a failed write-back is retried alone and an
  identity or mailbox is never created twice. Files are written to a temporary
  file and moved into place, so a crash cannot leave a half-written state.
- **Look before every create.** The lookup and the create are retried
  together, so if a create reached Entra but its response was lost, the retry
  finds that identity instead of making a second. The same lookup protects
  against a lost state file.
- **Bounded waiting.** A few mailbox checks per run and a 24-hour timeout to a
  visible exception state, instead of one execution waiting indefinitely.
- **Mocks with the real command names.** The mocks are `Get-MgUser`,
  `New-MgUser`, `Update-MgUser`, `Set-MgUserManagerByRef` and `Get-EXOMailbox`,
  with the real parameters and property names, so the pipeline code is what it
  would be in production. Moving to the real services means importing
  `Microsoft.Graph.Users` and `ExchangeOnlineManagement` instead.
- **Structured audit, minimal personal data.** JSON Lines loads straight into
  Log Analytics; lines are appended as each worker finishes, so a crashed run
  still leaves a record; and only the `employeeId` and object ID identify a
  worker.
- **One module per concern.** Rules, pipeline, retry, audit, files, display
  and mocks are separate, so each can be read, tested and changed on its own.

## Assumptions

- The HRIS input is a full export: every current worker, as one JSON array per
  run. A worker missing from one export is not treated as a leaver.
- `status` is exactly `Active` or `Inactive`. Anything else is malformed.
- `employeeId` is `E` followed by digits, and is unique and stable for a worker.
- Dates are `yyyy-MM-dd`, compared with today's local date. A worker is
  disabled on their end date.
- `managerEmployeeId` refers to another worker by `employeeId`, and the manager
  is set in Entra from their identity.
- New identities use `<employeeId>@<domain>` as the user principal name and
  `first.last` as the mail nickname. Exchange assigns the primary SMTP address
  from the nickname, adding a number when it is taken.
- Existing active workers also go through the write-back stage, so an HRIS
  record with no email gets it, a matching one is `NoChange`, and a different
  one is flagged.
- The HRIS write-back API authenticates callers with a token, supports an
  idempotency key, and refuses to overwrite a different address (`409`).
- One run at a time.

## Known limitations

- **Mocks only.** The Graph, Exchange and HRIS mocks behave like the real
  services in the ways that matter here, but have not been run against a real
  tenant. Their data is saved between runs in `IdentitySync/State` to stand in
  for real services remembering what was created.
- **No lock against two runs at once.** Two simultaneous runs could both
  create the same joiner. Production needs a lease or lock (see below).
- **Local state file.** The sync state is a JSON file on the machine that runs
  it. Losing it is safe (identities are looked up before any create), but
  workers that were part-way through start their stages again.
- **Full reads.** Every run lists all Entra users, which will not scale to a
  large tenant; production would use delta queries or per-worker lookups.
- **No licence assignment.** In a real tenant a mailbox appears only after an
  Exchange licence is assigned. The mocks start provisioning as soon as the
  user is created.
- **Names are not kept in sync** after creation, and a rehired leaver is not
  re-enabled automatically: both are left to a person.
- **No alerting.** Problems are visible in the terminal, the audit log and the
  stage summary, but nothing notifies anyone.
- **Mailbox timeout** is covered by tests that simulate 25 hours, not by a real
  wait.
- **Tested on Windows only** (Windows PowerShell 5.1 and PowerShell 7 in CI).

## What I would change for production

- **Real services.** Replace the mock module with `Microsoft.Graph.Users` and
  `ExchangeOnlineManagement`, and an HRIS API client; add licence assignment
  (ideally group-based) before waiting for the mailbox.
- **Run in Azure** on a schedule, as an Automation Account runbook with a
  managed identity, as in the [Azure design](docs/azure-design.md) and
  [`infra/main.bicep`](infra/main.bicep).
- **No stored secrets.** Managed identity for Graph and Exchange; the HRIS
  token in Key Vault, read at run time.
- **Least privilege.** Graph application permissions limited to what the sync
  needs, and an HRIS token that can only write the email field.
- **Shared, locked state.** Keep the sync state in Azure Storage with a blob
  lease, so only one run can hold it at a time.
- **Monitoring and alerts.** Send the audit log to Log Analytics and alert on
  `RunFailed`, a missed scheduled run, and any `ManualReview`,
  `MailboxTimeout` or failed stage.
- **A review queue.** Put `ManualReview` workers into a ticket or queue for the
  HRIS or identity team, rather than only the log.
- **Scale.** Delta queries for Entra, and Graph batching for large changes.
- **Change control.** Deploy runbook and infrastructure through the pipeline,
  with an approval gate before production and the dry run as a pre-check.
- **Retention.** A retention period for audit logs that matches data
  protection policy.

## AI-assisted development

**Tools used.** Claude Code (Anthropic's Claude) in the Claude desktop app, as a
pair programmer.

**What I used it for.**
- Reading the brief and breaking it into steps.
- Writing first drafts of the modules, tests, mocks, CI workflow and documents,
  which I then reviewed, ran and changed.
- Explaining PowerShell behaviour I hit along the way, such as Windows
  PowerShell 5.1 returning a JSON array as a single object.
- Suggesting test cases and ways to break the code on purpose to check the
  tests catch it.

**Suggestions I rejected or changed.** For example:
- It first collapsed identical duplicate HRIS records into one `Create`. I
  changed this so that *any* duplicate `employeeId` goes to `ManualReview`,
  because HR needs to delete the duplicate rather than have the sync guess.
- It first created future joiners' accounts disabled until their start date,
  with a rule to enable them later. I changed this to create them enabled, and
  removed the re-enable rule.
- Its mocks first had invented names (`New-MockEntraUser`, `Get-MockMailbox`).
  I asked for the real Microsoft Graph and Exchange Online command names, so
  the code reads like production code.
- It suggested also writing the audit log as CSV or text; I kept JSON Lines
  only, as the structured format a log tool can read.

**How I verified the result independently.**
- Ran every step myself in a PowerShell window, following a written test plan,
  and checked the terminal output, the state file and the audit log against
  what each test case in the brief expects.
- Ran the Pester tests, and read through each test to confirm it checks the
  right thing.
- Deliberately broke rules in the code (for example, disabling a day late,
  skipping the lookup before create, never retrying) and confirmed the tests
  failed.
- CI runs the linter and the tests on Windows PowerShell 5.1 and PowerShell 7
  on every push.
