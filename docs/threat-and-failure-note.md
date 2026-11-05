# Threat and failure note

What could go wrong with an automation that can create and disable accounts,
and what this design does about it. "Now" means what the code in this
repository does; "Production" means what the [Azure design](azure-design.md)
adds.

## Credentials

| Risk | Now | Production |
|---|---|---|
| A secret is stored in code, config or the repository | No secrets anywhere in the repository. The HRIS token is read from the `IDENTITYSYNC_HRIS_TOKEN` environment variable at run time. | Graph and Exchange use the Automation Account's **managed identity**: there is no secret to store or rotate. The HRIS token is in **Key Vault** and read at run time with the managed identity. |
| A secret leaks into logs, state or errors | The token and new users' passwords are never printed, saved to the state file, or written to the audit log. Error messages from the mocks never echo the token. Tests check all three. | Same, plus Key Vault access logs show every read of the token. |
| New users' initial passwords | Generated per user from a cryptographic random source, passed straight to `New-MgUser` with "change at next sign-in", and never kept. | Same; or, better, no password at all: issue a Temporary Access Pass or use passwordless onboarding. |
| A stolen HRIS token is replayed | The HRIS API checks the token before anything else (`401`). | Short-lived token from the HRIS, rotated in Key Vault; network restrictions on the HRIS API. |

## Least privilege

| Access | Needed for | Granted |
|---|---|---|
| Microsoft Graph `User.ReadWrite.All` (application) | Read users, create joiners, update department, disable leavers, set managers | Only this permission, to the managed identity. Not `Directory.ReadWrite.All`, and no admin roles. Could be narrowed further with an administrative unit for user accounts in scope. |
| Exchange Online `Exchange.ManageAsApp` plus the **Global Reader** Microsoft Entra role | `Get-EXOMailbox` to read the primary SMTP address | Read-only: the sync never changes a mailbox. Global Reader is the least privileged of the roles Microsoft supports for a managed identity in Exchange Online PowerShell; it can read more than mailboxes, so this is a known trade-off. |
| HRIS API | Read a worker and write the `email` field | A token scoped to the email field only, not the whole worker record. |
| Azure Storage (state and audit containers) | Read and write the sync state and audit logs | `Storage Blob Data Contributor` on that one storage account. Shared key access is disabled. |
| Key Vault | Read the HRIS token | `Key Vault Secrets User` on that one vault. |
| People | Change the runbook or the infrastructure | Through the repository and pipeline only, with review. |

## Destructive actions

Disabling the wrong people is the worst realistic outcome, so several separate
safeguards stand between an HRIS export and a disable:

1. **Dry run by default.** Nothing changes without `-Apply`.
2. **Two signals.** Disable only when the status is `Inactive` **and** the end
   date has passed. If they disagree, `ManualReview`.
3. **Missing is not leaving.** An identity with no HRIS record is reported and
   left alone.
4. **Disable, never delete.** A disabled account can be re-enabled in seconds
   with nothing lost.
5. **A limit per run.** If more than five disables are planned, none are
   applied, and every one is reported as held back. A large batch of leavers
   is more likely a broken export than real departures.
6. **No guessing.** Duplicate HRIS records, two identities with one
   `employeeId`, and any validation failure go to `ManualReview`.
7. **Narrow updates.** An update changes only department and manager, never
   names; a different email in the HRIS is never overwritten.

## Replay and idempotency

| Risk | Protection |
|---|---|
| The same input is processed twice | Finished workers are skipped. Decisions compare against the current state of Entra, so a second run of the same input decides `NoChange`. |
| A run is restarted part-way | Each stage is saved as soon as it completes, and a run carries on from the last stage saved. |
| A create succeeded but its response was lost | Every create attempt looks up the `employeeId` first, inside the same retry, so a create that already happened is found rather than repeated. |
| The state file is lost | The same lookup finds existing identities; workers carry on without duplicates. |
| An HRIS write is sent twice | Each write carries an idempotency key (`employeeId:address`). A repeat returns the first result without writing again; a key reused for a different request is rejected (`422`). |
| Duplicate records in one input | Sent to `ManualReview`, so a duplicated row can never cause two actions. |
| Two runs at the same time | **Not handled locally.** In production the state is held under a blob lease, so a second run cannot start until the first finishes. |

## Monitoring

**Now**: every run writes a JSON Lines audit log with a correlation ID on every
line, and the terminal shows a per-worker result and a summary by stage.

**Production**: the audit lines go to Log Analytics, and alerts fire on:

| Signal | Why |
|---|---|
| `RunFailed`, or a runbook job that failed | The sync stopped with an error. |
| No `RunCompleted` in the expected window | The schedule stopped running. |
| Any `ManualReview` or `MailboxTimeout` | A person needs to act: duplicate or invalid HRIS data, an ambiguous identity, a conflicting email, or a mailbox that never appeared (usually licensing). |
| The same `IdentityFailed` or `WriteBackFailed` across several runs | A dependency is down for longer than retries can cover. |
| Disables held back by the limit | Probably a bad HRIS export. |
| A high `retryCount` | Throttling: the schedule may be too frequent. |

## Recovery

| Failure | Effect | Recovery |
|---|---|---|
| Graph, Exchange or HRIS briefly unavailable (`429`, `5xx`) | Retried up to 4 times with back-off within the run. | Automatic. |
| A dependency down for longer | The stage is recorded as failed. | Automatic: the next run retries just that stage. |
| Mailbox never provisioned | `MailboxTimeout` after 24 hours, no write-back. | A person fixes the cause (often the licence), then resets that worker's state entry. |
| Conflicting email in the HRIS | `ManualReview`; the HRIS address is untouched. | The HRIS team decides which address is right. |
| Bad HRIS export | Invalid records go to `ManualReview`; a mass disable is held back by the limit. | Fix the export and run again. |
| A worker disabled in error | Account disabled, nothing deleted. | Re-enable the account; correct the HRIS record so it is not disabled again. |
| Process crashes mid-run | Stages completed so far are saved; the audit log shows how far it got. | Run again: it carries on from the saved stages. |
| State file corrupted | The run refuses to start rather than ignore it. | Restore it from storage versioning, or delete it: existing identities are found by lookup, and nothing is duplicated. |
| Wrong change deployed | | Roll back the runbook through the pipeline; dry-run the previous version first. |
