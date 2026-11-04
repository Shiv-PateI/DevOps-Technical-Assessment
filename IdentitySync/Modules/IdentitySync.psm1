<#
.SYNOPSIS
    Validation and decision logic for the HRIS to Entra ID identity sync.

.DESCRIPTION
    This module decides what should happen to each worker's identity. It does
    not call any API or change anything: every function here takes data in and
    returns a result, which keeps the rules easy to test and makes a dry run
    safe by design.

    Public functions:
      Test-WorkerRecord       Checks one HRIS record and lists any problems.
      Get-IdentityDecision    Decides the action for one worker, given the
                              Entra identities that share its employeeId.
      Get-IdentityPlan        Decides the action for every worker in a file,
                              handling duplicate records first.
      Get-UnmatchedIdentity   Lists Entra identities with no HRIS record, which
                              are reported but never changed.

    Every decision has one of five actions: Create, Update, Disable, NoChange
    or ManualReview, plus a reason and the attribute changes it would make.

    Workers are matched to identities by employeeId only, never by name or
    email address.
#>

Set-StrictMode -Version Latest

#region Rules
# employeeId must be an upper-case E followed by digits, for example E1042.
$script:EmployeeIdPattern = '^E\d+$'

# The only accepted status values. Matching is case-sensitive: anything else,
# including 'active', is treated as malformed rather than guessed at.
$script:ValidStatuses = @('Active', 'Inactive')

# Fields a record must have before it can be handled safely.
$script:RequiredFields = @('employeeId', 'status', 'firstName', 'lastName', 'startDate')

# The only accepted date format, matching the HRIS input.
$script:DateFormat = 'yyyy-MM-dd'

# HRIS fields set when an identity is created, and the Entra attribute each one maps to.
$script:CreateAttributes = [ordered]@{
    firstName         = 'givenName'
    lastName          = 'surname'
    department        = 'department'
    managerEmployeeId = 'managerEmployeeId'
}

# HRIS fields kept in sync on an existing identity. An Update only ever touches
# these attributes; names are set once at creation and not changed afterwards.
$script:SyncedAttributes = [ordered]@{
    department        = 'department'
    managerEmployeeId = 'managerEmployeeId'
}
#endregion

#region Private helpers
# Returns a property from a record, or $null when it is missing. Strict mode
# throws on missing properties, and HRIS records may be missing fields.
function Get-RecordValue {
    param($Record, [string] $Name)

    if ($null -eq $Record) { return $null }
    $property = $Record.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Parses a date in the exact yyyy-MM-dd format, or returns $null.
# ParseExact means a value like 14/11/2026 is rejected instead of being read
# as a UK or US date.
function ConvertTo-WorkerDate {
    param($Value)

    # PowerShell 7 can turn ISO date strings into DateTime while reading JSON.
    if ($Value -is [datetime]) { return $Value.Date }
    if ($Value -isnot [string]) { return $null }

    $parsed = [datetime]::MinValue
    $isValid = [datetime]::TryParseExact($Value, $script:DateFormat,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref] $parsed)
    if ($isValid) { return $parsed }
    return $null
}

# True when a value is missing or blank.
function Test-IsBlank {
    param($Value)
    return ($null -eq $Value) -or [string]::IsNullOrWhiteSpace([string] $Value)
}

# Describes a single attribute change, from its current value to the new one.
function New-AttributeChange {
    param($From, $To)
    [pscustomobject]@{ From = $From; To = $To }
}

# Builds the decision object returned for every worker.
function New-Decision {
    param(
        $Worker,
        [string] $Action,
        [string] $Reason,
        [System.Collections.Specialized.OrderedDictionary] $Changes = ([ordered]@{})
    )

    $name = '{0} {1}' -f (Get-RecordValue $Worker 'firstName'), (Get-RecordValue $Worker 'lastName')
    [pscustomobject]@{
        PSTypeName = 'IdentitySync.Decision'
        EmployeeId = Get-RecordValue $Worker 'employeeId'
        Name       = $name.Trim()
        Action     = $Action
        Reason     = $Reason
        Changes    = $Changes
    }
}
#endregion

#region Validation
function Test-WorkerRecord {
    <#
    .SYNOPSIS
        Checks one HRIS worker record and returns a list of problems.
    .DESCRIPTION
        Returns nothing when the record is valid. Any problem means the record
        cannot be handled safely and must go to ManualReview.
    .EXAMPLE
        $problems = @(Test-WorkerRecord -Worker $worker)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] $Worker)

    $problems = [System.Collections.Generic.List[string]]::new()

    # Required fields must be present and not blank.
    foreach ($field in $script:RequiredFields) {
        if (Test-IsBlank (Get-RecordValue $Worker $field)) {
            $problems.Add("Missing required field '$field'")
        }
    }

    # employeeId is the only identifier, so its format must be exact.
    $employeeId = Get-RecordValue $Worker 'employeeId'
    if (-not (Test-IsBlank $employeeId) -and ([string] $employeeId -cnotmatch $script:EmployeeIdPattern)) {
        $problems.Add("employeeId '$employeeId' is not in the expected format (E followed by digits)")
    }

    # status must be one of the known values, with exact case.
    $status = Get-RecordValue $Worker 'status'
    if (-not (Test-IsBlank $status) -and ($script:ValidStatuses -cnotcontains [string] $status)) {
        $problems.Add("status '$status' is not one of: $($script:ValidStatuses -join ', ')")
    }

    # Dates must be real dates in yyyy-MM-dd format.
    $startValue = Get-RecordValue $Worker 'startDate'
    $startDate  = ConvertTo-WorkerDate $startValue
    if (-not (Test-IsBlank $startValue) -and ($null -eq $startDate)) {
        $problems.Add("startDate '$startValue' is not a valid $($script:DateFormat) date")
    }

    $endValue = Get-RecordValue $Worker 'endDate'
    $endDate  = ConvertTo-WorkerDate $endValue
    if (-not (Test-IsBlank $endValue) -and ($null -eq $endDate)) {
        $problems.Add("endDate '$endValue' is not a valid $($script:DateFormat) date")
    }

    if ($startDate -and $endDate -and ($endDate -lt $startDate)) {
        $problems.Add("endDate $endValue is before startDate $startValue")
    }

    # A leaver must say when they left, otherwise a disable cannot be justified.
    if (([string] $status -ceq 'Inactive') -and (Test-IsBlank $endValue)) {
        $problems.Add('status is Inactive but endDate is missing')
    }

    # The manager reference must also be a valid employeeId, and not the worker themself.
    $managerId = Get-RecordValue $Worker 'managerEmployeeId'
    if (-not (Test-IsBlank $managerId)) {
        if ([string] $managerId -cnotmatch $script:EmployeeIdPattern) {
            $problems.Add("managerEmployeeId '$managerId' is not in the expected format (E followed by digits)")
        }
        elseif ([string] $managerId -ceq [string] $employeeId) {
            $problems.Add('managerEmployeeId is the worker themself')
        }
    }

    $problems.ToArray()
}
#endregion

#region Decisions
function Get-IdentityDecision {
    <#
    .SYNOPSIS
        Decides the identity action for one worker.
    .DESCRIPTION
        Rules are checked in order and the first match wins:
          1. Invalid record                              -> ManualReview
          2. More than one identity with this employeeId -> ManualReview
          3. Status and end date contradict each other   -> ManualReview
          4. No identity, leaver                         -> NoChange
          5. No identity, joiner                         -> Create (disabled until
                                                            the start date if it
                                                            is in the future)
          6. Identity exists, leaver, still enabled      -> Disable
          7. Identity exists, leaver, already disabled   -> NoChange
          8. Identity exists, active, department or      -> Update (changed
             manager differs                                attributes only;
                                                            names are never
                                                            updated)
          9. Identity exists and matches                 -> NoChange
    .PARAMETER Worker
        One HRIS worker record.
    .PARAMETER Identities
        The Entra identities whose employeeId matches the worker. Pass an
        empty array when there are none.
    .PARAMETER Today
        The date the rules treat as today. Defaults to the current date.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Worker,
        [AllowEmptyCollection()] [object[]] $Identities = @(),
        [datetime] $Today = (Get-Date).Date
    )

    $Today      = $Today.Date
    $employeeId = Get-RecordValue $Worker 'employeeId'

    # 1. A record that fails validation is never acted on.
    $problems = @(Test-WorkerRecord -Worker $Worker)
    if ($problems.Count -gt 0) {
        return New-Decision $Worker 'ManualReview' ('Record failed validation: {0}' -f ($problems -join '; '))
    }

    # 2. Two identities claiming one employeeId means the directory is already
    #    inconsistent. Picking one would be a guess.
    $Identities = @($Identities | Where-Object { $null -ne $_ })
    if ($Identities.Count -gt 1) {
        return New-Decision $Worker 'ManualReview' (
            '{0} Entra identities have employeeId {1}; refusing to guess which is correct' -f $Identities.Count, $employeeId)
    }

    $status    = [string] (Get-RecordValue $Worker 'status')
    $startDate = ConvertTo-WorkerDate (Get-RecordValue $Worker 'startDate')
    $endDate   = ConvertTo-WorkerDate (Get-RecordValue $Worker 'endDate')
    $hasLeft   = ($null -ne $endDate) -and ($endDate -le $Today)
    $endText   = Get-RecordValue $Worker 'endDate'

    # 3. Disabling needs both signals to agree: status Inactive AND an end date
    #    that has passed. If they disagree, a person has to look.
    if (($status -ceq 'Active') -and $hasLeft) {
        return New-Decision $Worker 'ManualReview' "status is Active but endDate $endText has passed; the record contradicts itself"
    }
    if (($status -ceq 'Inactive') -and -not $hasLeft) {
        return New-Decision $Worker 'ManualReview' "status is Inactive but endDate $endText is in the future; the record contradicts itself"
    }

    # 4 and 5. No identity yet.
    if ($Identities.Count -eq 0) {
        if ($status -ceq 'Inactive') {
            return New-Decision $Worker 'NoChange' 'Worker has left and no identity exists; nothing to disable'
        }

        # A new identity gets its name, department and manager.
        $changes = [ordered]@{}
        foreach ($hrisField in $script:CreateAttributes.Keys) {
            $changes[$script:CreateAttributes[$hrisField]] = New-AttributeChange $null (Get-RecordValue $Worker $hrisField)
        }

        # Future joiners get their account now, but disabled, so it is ready on
        # day one without being usable before the start date.
        $startsLater = $startDate -gt $Today
        $changes['accountEnabled'] = New-AttributeChange $null (-not $startsLater)
        if ($startsLater) {
            $reason = 'New joiner starting {0}; create the identity disabled until the start date' -f $startDate.ToString($script:DateFormat)
        }
        else {
            $reason = 'New joiner with no existing identity'
        }
        return New-Decision $Worker 'Create' $reason $changes
    }

    $identity = $Identities[0]
    $enabled  = [bool] (Get-RecordValue $identity 'accountEnabled')

    # 6 and 7. Leaver with an identity.
    if ($status -ceq 'Inactive') {
        if ($enabled) {
            $changes = [ordered]@{ accountEnabled = New-AttributeChange $true $false }
            return New-Decision $Worker 'Disable' "Worker left on $endText (status Inactive and end date passed); the identity is still enabled" $changes
        }
        return New-Decision $Worker 'NoChange' 'Worker has left and the identity is already disabled'
    }

    # 8 and 9. Active worker with an identity: compare only department and manager.
    $changes = [ordered]@{}
    foreach ($hrisField in $script:SyncedAttributes.Keys) {
        $entraField = $script:SyncedAttributes[$hrisField]
        $current    = Get-RecordValue $identity $entraField
        $wanted     = Get-RecordValue $Worker $hrisField

        # Compared as strings so that $null and '' count as the same empty value.
        if ([string] $current -cne [string] $wanted) {
            $changes[$entraField] = New-AttributeChange $current $wanted
        }
    }

    # An identity created disabled for a future joiner is enabled once the start date arrives.
    $hasStarted = $startDate -le $Today
    if (-not $enabled -and $hasStarted) {
        $changes['accountEnabled'] = New-AttributeChange $false $true
    }

    if ($changes.Count -eq 0) {
        if (-not $enabled) {
            return New-Decision $Worker 'NoChange' 'Identity matches the HRIS record and stays disabled until the start date'
        }
        return New-Decision $Worker 'NoChange' 'Identity already matches the HRIS record'
    }
    return New-Decision $Worker 'Update' ('Changed attributes: {0}' -f (@($changes.Keys) -join ', ')) $changes
}

function Get-IdentityPlan {
    <#
    .SYNOPSIS
        Decides the identity action for every worker in an HRIS file.
    .DESCRIPTION
        Groups records by employeeId first, so each employeeId gets exactly one
        decision:
          - identical duplicate records are treated as one record
          - duplicate records that disagree go to ManualReview
          - records with no employeeId are each decided on their own (and fail
            validation), never grouped together
        Each worker is then decided against the Entra identities with the same
        employeeId. Decisions come back in the order the workers first appear.
    .PARAMETER Workers
        Every HRIS worker record in the input.
    .PARAMETER Identities
        Every Entra identity currently known.
    .PARAMETER Today
        The date the rules treat as today. Defaults to the current date.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Workers,
        [AllowEmptyCollection()] [object[]] $Identities = @(),
        [datetime] $Today = (Get-Date).Date
    )

    # Group records by employeeId. A Dictionary compares keys case-sensitively,
    # so E1001 and e1001 are never merged; $order keeps the input order.
    $groups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new()
    $order  = [System.Collections.Generic.List[string]]::new()
    $index  = 0
    foreach ($worker in $Workers) {
        $index++
        $employeeId = Get-RecordValue $worker 'employeeId'

        # Records without an employeeId get a unique key each, so they are never merged.
        $key = if (Test-IsBlank $employeeId) { "#missing-$index" } else { [string] $employeeId }

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
            $order.Add($key)
        }
        $groups[$key].Add($worker)
    }

    foreach ($key in $order) {
        $records = $groups[$key]

        # Identities are matched on employeeId only, with exact case.
        $matching = @($Identities | Where-Object { [string] (Get-RecordValue $_ 'employeeId') -ceq $key })

        if ($records.Count -eq 1) {
            Get-IdentityDecision -Worker $records[0] -Identities $matching -Today $Today
            continue
        }

        # Several records share this employeeId. Compare their full content.
        $distinct = @($records | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 5 } | Select-Object -Unique)
        if ($distinct.Count -eq 1) {
            $decision = Get-IdentityDecision -Worker $records[0] -Identities $matching -Today $Today
            $decision.Reason = '{0} ({1} identical records for this employeeId were treated as one)' -f $decision.Reason, $records.Count
            $decision
        }
        else {
            New-Decision $records[0] 'ManualReview' (
                '{0} records share employeeId {1} but disagree; refusing to guess which is correct' -f $records.Count, $key)
        }
    }
}

function Get-UnmatchedIdentity {
    <#
    .SYNOPSIS
        Returns the Entra identities that have no record in the HRIS input.
    .DESCRIPTION
        A worker missing from one input file is not proof they have left, so
        these identities are reported and left unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Workers,
        [AllowEmptyCollection()] [object[]] $Identities = @()
    )

    $inputIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($worker in $Workers) {
        $employeeId = Get-RecordValue $worker 'employeeId'
        if (-not (Test-IsBlank $employeeId)) { [void] $inputIds.Add([string] $employeeId) }
    }

    $Identities | Where-Object { -not $inputIds.Contains([string] (Get-RecordValue $_ 'employeeId')) }
}
#endregion

Export-ModuleMember -Function Test-WorkerRecord, Get-IdentityDecision, Get-IdentityPlan, Get-UnmatchedIdentity
