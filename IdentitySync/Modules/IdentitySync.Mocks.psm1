<#
.SYNOPSIS
    In-memory mocks of Microsoft Graph (Entra ID), Exchange Online and the
    HRIS write-back API.

.DESCRIPTION
    Stand-ins for the three external systems, so the sync can be run and
    tested without a live tenant or HRIS.

    The Entra ID and Exchange Online mocks use the same command names and
    main parameters as the real modules (Microsoft.Graph.Users and
    ExchangeOnlineManagement), and return objects with the same property
    names. Code written against these mocks therefore reads exactly like
    production code, and moving to the real services means importing the
    real modules instead of this one.

    Never load this module and the real modules in the same session: the
    commands share names, and whichever was loaded last would be used.

    Mock-only commands (not part of any real module):
      Initialize-MockServices   Loads the mock data and behaviour. Call first.
      Save-MockServices         Saves the mock data so the next run carries on.
      Set-MockActivityOutput    Turns the activity lines on or off.

    Microsoft Graph (Microsoft.Graph.Authentication / Microsoft.Graph.Users):
      Connect-MgGraph           Connects. Accepts -Identity, -Scopes, etc.
      Disconnect-MgGraph        Disconnects.
      Get-MgUser                Gets a user by -UserId, or lists users with
                                -Filter "employeeId eq 'E1001'".
      New-MgUser                Creates a user. Its mailbox starts provisioning.
      Update-MgUser             Changes department, account enabled and names.
      Set-MgUserManagerByRef    Sets a user's manager.

    Exchange Online (ExchangeOnlineManagement):
      Connect-ExchangeOnline    Connects. Accepts -ManagedIdentity, etc.
      Disconnect-ExchangeOnline Disconnects.
      Get-EXOMailbox            Gets a mailbox and its PrimarySmtpAddress.
                                Like the real command, it fails with "not
                                found" until a new mailbox has been provisioned.

    HRIS (there is no Microsoft equivalent; these model a typical REST API):
      Get-HRISWorker            Reads one worker by employeeId.
      Set-HRISWorkerEmail       Writes a confirmed email to one worker.

    How the mocks behave:
      Entra ID         Users are found by employeeId with an exact match. A
                       new user gets a new object ID and no mail address yet.
                       userPrincipalName must be unique, as in the real service.
      Exchange Online  A new mailbox is not found for a number of checks, then
                       appears with its primary SMTP address. Exchange assigns
                       the address from the mail nickname, so it can differ
                       from the one requested (alex.clarke2@ when alex.clarke@
                       is taken). Once ready, the user's Mail is set too.
      HRIS             An authentication boundary (an API token), input
                       validation, idempotent writes with an idempotency key,
                       and a refusal to overwrite a different address.

    Failures are simulated the way a real REST call fails: the command throws
    an exception whose Data['StatusCode'] holds the HTTP status (400, 401,
    404, 409, 422, 429, 503), and Data['RetryAfterSeconds'] for a 429. Which
    employeeIds fail is set in Mocks\mock-behaviour.json.

    Every call prints a line saying what the mock did, for example
      [Entra mock]     Created user E9013 Alex Clarke (object ID ...)
    Passwords and API tokens are never printed. The mocks keep their state in
    memory only, so it resets each time Initialize-MockServices runs.
#>

Set-StrictMode -Version Latest

# Whether each mock call prints a line saying what it did. On by default.
$script:ShowActivity = $true

# Spaces printed before each activity line.
$script:ActivityIndent = 0

# The mock data, set by Initialize-MockServices.
$script:State = $null

# Which services have been connected to since Initialize-MockServices.
$script:Connected = @{ Graph = $false; Exchange = $false }

#region Private helpers
# Returns a property from an object, or $null when it is missing. Behaviour
# settings and records are optional, and strict mode throws on missing properties.
function Get-MockValue {
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Prints one line saying what a mock did, for example:
#   [Exchange mock]  Mailbox for E9013 found: alex.clarke@example.com
# The source tag is in dark cyan and the message in the colour given.
function Write-MockActivity {
    param(
        [ValidateSet('Entra', 'Exchange', 'HRIS')] [string] $Source,
        [string] $Message,
        [string] $Colour = 'White'
    )

    if (-not $script:ShowActivity) { return }
    Write-Host ((' ' * $script:ActivityIndent) + ('{0,-17}' -f "[$Source mock]")) -ForegroundColor DarkCyan -NoNewline
    Write-Host $Message -ForegroundColor $Colour
}

# Builds the exception a failed HTTP call would raise, and prints it in red
# (unless -Silent, for expected failures that are reported differently). The
# status code goes in Data so callers can tell a retryable failure (429, 503)
# from a permanent one. Messages never include passwords or tokens.
function New-MockHttpError {
    param(
        [string] $Source,
        [int] $StatusCode,
        [string] $Message,
        [int] $RetryAfterSeconds = 0,
        [switch] $Silent
    )

    if (-not $Silent) {
        Write-MockActivity -Source $Source -Message "HTTP $StatusCode`: $Message" -Colour Red
    }

    $exception = [System.InvalidOperationException]::new("HTTP $StatusCode`: $Message")
    $exception.Data['StatusCode'] = $StatusCode
    if ($RetryAfterSeconds -gt 0) {
        $exception.Data['RetryAfterSeconds'] = $RetryAfterSeconds
    }
    $exception
}

# Stops with a clear message if Initialize-MockServices has not been run.
function Assert-MockInitialized {
    if ($null -eq $script:State) {
        throw 'The mock services are not set up. Run Initialize-MockServices first.'
    }
}

# Stops with a 401, as the real modules do, when the service is not connected.
function Assert-MockConnected {
    param([ValidateSet('Graph', 'Exchange')] [string] $Service)

    Assert-MockInitialized
    if (-not $script:Connected[$Service]) {
        if ($Service -eq 'Graph') {
            throw (New-MockHttpError -Source 'Entra' -StatusCode 401 -Message 'Authentication needed. Please call Connect-MgGraph.')
        }
        throw (New-MockHttpError -Source 'Exchange' -StatusCode 401 -Message 'Not connected. Please call Connect-ExchangeOnline.')
    }
}

# Throws the failure configured in the behaviour file for this employeeId, if
# any. "times" is a number of calls to fail before succeeding, or "always".
# Calls are counted per service and employeeId.
function Invoke-ConfiguredFailure {
    param(
        [string] $Source,
        [string] $Section,
        [string] $EmployeeId
    )

    if (-not $EmployeeId) { return }
    $failures = Get-MockValue (Get-MockValue $script:State.Behaviour $Section) 'failures'
    $failure  = Get-MockValue $failures $EmployeeId
    if ($null -eq $failure) { return }

    $counterKey = "$Section`:$EmployeeId"
    $script:State.CallCounts[$counterKey] = 1 + [int] $script:State.CallCounts[$counterKey]

    $times = Get-MockValue $failure 'times'
    if (($times -eq 'always') -or ($script:State.CallCounts[$counterKey] -le [int] $times)) {
        $statusCode = [int] (Get-MockValue $failure 'statusCode')
        $retryAfter = if ($statusCode -eq 429) { 1 } else { 0 }
        throw (New-MockHttpError -Source $Source -StatusCode $statusCode -RetryAfterSeconds $retryAfter `
            -Message "simulated failure for $EmployeeId (call $($script:State.CallCounts[$counterKey]))")
    }
}

# Works out the primary SMTP address Exchange assigns from the mail nickname:
# nickname@domain, or nickname2@domain, nickname3@domain and so on when taken.
function Get-AssignedAddress {
    param([string] $MailNickname)

    # Keep only letters, digits and dots, so names with spaces or apostrophes still work.
    $nickname  = $MailNickname.ToLowerInvariant() -replace '[^a-z0-9.]', ''
    $domain    = $script:State.MailDomain
    $candidate = $nickname
    $suffix    = 2
    while ($script:State.TakenAddresses.Contains("$candidate@$domain")) {
        $candidate = "$nickname$suffix"
        $suffix++
    }
    $address = "$candidate@$domain"
    [void] $script:State.TakenAddresses.Add($address)
    $address
}

# Finds the stored user with this object ID or userPrincipalName, or returns $null.
function Find-StoredUser {
    param([string] $Identity)

    $script:State.Users | Where-Object {
        ($_.id -ceq $Identity) -or ([string] (Get-MockValue $_ 'userPrincipalName') -eq $Identity) -or
        ([string] (Get-MockValue $_ 'mail') -eq $Identity)
    } | Select-Object -First 1
}

# Returns a stored user in the shape Get-MgUser returns: a MicrosoftGraphUser
# with PascalCase properties. With -ExpandManager, Manager holds the manager's
# Id and, in AdditionalProperties, their employeeId and displayName, as the
# real -ExpandProperty manager does.
function ConvertTo-MgUserObject {
    param($User, [switch] $ExpandManager)

    $manager = $null
    if ($ExpandManager) {
        $managerId   = Get-MockValue $User 'managerEmployeeId'
        $managerUser = if ($managerId) {
            $script:State.Users | Where-Object { [string] (Get-MockValue $_ 'employeeId') -ceq $managerId } | Select-Object -First 1
        }
        if ($managerUser) {
            $manager = [pscustomobject]@{
                Id                   = $managerUser.id
                AdditionalProperties = @{
                    employeeId  = $managerUser.employeeId
                    displayName = Get-MockValue $managerUser 'displayName'
                }
            }
        }
    }

    [pscustomobject]@{
        PSTypeName        = 'Microsoft.Graph.PowerShell.Models.MicrosoftGraphUser'
        Id                = $User.id
        DisplayName       = Get-MockValue $User 'displayName'
        GivenName         = Get-MockValue $User 'givenName'
        Surname           = Get-MockValue $User 'surname'
        UserPrincipalName = Get-MockValue $User 'userPrincipalName'
        Mail              = Get-MockValue $User 'mail'
        EmployeeId        = Get-MockValue $User 'employeeId'
        Department        = Get-MockValue $User 'department'
        AccountEnabled    = [bool] (Get-MockValue $User 'accountEnabled')
        Manager           = $manager
    }
}

# Checks the HRIS API token. The token is compared but never echoed back.
function Assert-HRISToken {
    param([string] $Token)

    Assert-MockInitialized
    if ([string]::IsNullOrEmpty($Token) -or ($Token -cne $script:State.HRISApiToken)) {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 401 -Message 'missing or invalid API token')
    }
}

# Finds the one HRIS worker with this employeeId, or throws 404 (none) or 409 (more than one).
function Get-HRISWorkerRecord {
    param([string] $EmployeeId)

    $found = @($script:State.HRISWorkers | Where-Object { [string] (Get-MockValue $_ 'employeeId') -ceq $EmployeeId })
    if ($found.Count -eq 0) {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 404 -Message "no HRIS worker with employeeId $EmployeeId")
    }
    if ($found.Count -gt 1) {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 409 -Message "$($found.Count) HRIS workers have employeeId $EmployeeId")
    }
    $found[0]
}
#endregion

#region Mock-only commands
function Initialize-MockServices {
    <#
    .SYNOPSIS
        Loads the mock Entra ID, Exchange Online and HRIS data. Run this first.
    .DESCRIPTION
        Replaces any earlier mock state and disconnects from both services.
        Every record passed in is copied, so the input is never changed.
        Existing Entra users get a mailbox that is already provisioned with
        their mail address.
    .PARAMETER Identities
        Existing Entra users, as in Mocks\Entra-Identities.json.
    .PARAMETER Workers
        HRIS worker records, as in Mocks\HRIS-Workers.json.
    .PARAMETER Behaviour
        Simulated failures and mailbox timing, as in Mocks\mock-behaviour.json.
        Without it, nothing fails and mailboxes are found on the second check.
    .PARAMETER HRISApiToken
        The token HRIS callers must send. In a real deployment this would come
        from a secret store; it is never written to output or errors.
    .PARAMETER FromPath
        A file written earlier by Save-MockServices. When it exists, the mock
        data is restored from it instead of from -Identities and -Workers, so
        users, mailboxes and HRIS emails created by an earlier run are still
        there, as they would be in the real services. -Behaviour and
        -HRISApiToken still apply.
    .EXAMPLE
        Initialize-MockServices -Identities $identities -Workers $workers -Behaviour $behaviour -HRISApiToken 'test-token'
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Identities = @(),
        [AllowEmptyCollection()] [object[]] $Workers = @(),
        $Behaviour,
        [string] $HRISApiToken = 'test-token',
        [string] $FromPath
    )

    $mailDomain = Get-MockValue $Behaviour 'mailDomain'
    if (-not $mailDomain) { $mailDomain = 'example.com' }

    $state = [pscustomobject]@{
        Users             = [System.Collections.Generic.List[object]]::new()
        Mailboxes         = @{}
        TakenAddresses    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        CallCounts        = @{}
        Behaviour         = $Behaviour
        MailDomain        = $mailDomain
        HRISWorkers       = [System.Collections.Generic.List[object]]::new()
        HRISApiToken      = $HRISApiToken
        IdempotentResults = @{}
    }

    # Restore the data saved by an earlier run, if there is any.
    $savedPath = if ($FromPath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FromPath) }
    if ($savedPath -and (Test-Path -Path $savedPath -PathType Leaf)) {
        $saved = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($savedPath))

        foreach ($user in @($saved.Users)) { if ($user) { $state.Users.Add($user) } }
        foreach ($worker in @($saved.HRISWorkers)) { if ($worker) { $state.HRISWorkers.Add($worker) } }
        foreach ($address in @($saved.TakenAddresses)) { if ($address) { [void] $state.TakenAddresses.Add($address) } }
        foreach ($entry in $saved.Mailboxes.PSObject.Properties) {
            $state.Mailboxes[$entry.Name] = @{
                EmployeeId = $entry.Value.EmployeeId
                Address    = $entry.Value.Address
                Checks     = [int] $entry.Value.Checks
                Ready      = [bool] $entry.Value.Ready
            }
        }
        foreach ($entry in $saved.CallCounts.PSObject.Properties) { $state.CallCounts[$entry.Name] = [int] $entry.Value }
        foreach ($entry in $saved.IdempotentResults.PSObject.Properties) {
            $state.IdempotentResults[$entry.Name] = @{ Request = $entry.Value.Request; Result = $entry.Value.Result }
        }

        $script:State     = $state
        $script:Connected = @{ Graph = $false; Exchange = $false }
        Write-MockActivity -Source 'Entra' -Colour Green -Message ('Mock tenant restored from the last run: {0} users' -f $state.Users.Count)
        Write-MockActivity -Source 'HRIS' -Colour Green -Message ('Mock HRIS restored from the last run: {0} worker records' -f $state.HRISWorkers.Count)
        return
    }

    foreach ($identity in $Identities) {
        # Copy each user, filling in the properties a real directory always has.
        $user = $identity.PSObject.Copy()
        if (-not (Get-MockValue $user 'displayName')) {
            $user | Add-Member -NotePropertyName displayName -NotePropertyValue ('{0} {1}' -f $user.givenName, $user.surname) -Force
        }
        if (-not (Get-MockValue $user 'userPrincipalName')) {
            $user | Add-Member -NotePropertyName userPrincipalName -NotePropertyValue ('{0}@{1}' -f $user.employeeId, $mailDomain) -Force
        }
        $state.Users.Add($user)

        $mail = Get-MockValue $user 'mail'
        if ($mail) { [void] $state.TakenAddresses.Add($mail) }
        $state.Mailboxes[$user.id] = @{
            EmployeeId = $user.employeeId
            Address    = $mail
            Checks     = 0
            Ready      = [bool] $mail
        }
    }
    foreach ($worker in $Workers) {
        $state.HRISWorkers.Add($worker.PSObject.Copy())
    }

    $script:State     = $state
    $script:Connected = @{ Graph = $false; Exchange = $false }

    Write-MockActivity -Source 'Entra' -Colour Green -Message ('Mock tenant loaded: {0} users, mail domain {1}' -f $state.Users.Count, $mailDomain)
    Write-MockActivity -Source 'HRIS' -Colour Green -Message ('Mock HRIS loaded: {0} worker records; calls need an API token' -f $state.HRISWorkers.Count)
}

function Save-MockServices {
    <#
    .SYNOPSIS
        Saves the mock data to a file, so the next run can carry on from it.
    .DESCRIPTION
        The real services keep their data between runs; the mocks only live in
        memory. Saving them after each change, and restoring with
        Initialize-MockServices -FromPath, means a second run sees the users,
        mailboxes and HRIS emails the first run created. The HRIS API token
        and the behaviour settings are not saved.
    .EXAMPLE
        Save-MockServices -Path .\State\mock-services.json
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    Assert-MockInitialized
    $fullPath  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Path $fullPath -Parent
    if (-not (Test-Path -Path $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $snapshot = [ordered]@{
        Users             = @($script:State.Users)
        Mailboxes         = $script:State.Mailboxes
        TakenAddresses    = @($script:State.TakenAddresses)
        CallCounts        = $script:State.CallCounts
        HRISWorkers       = @($script:State.HRISWorkers)
        IdempotentResults = $script:State.IdempotentResults
    }

    # Written to a temporary file first, then moved into place.
    $tempPath = '{0}.tmp' -f $fullPath
    [System.IO.File]::WriteAllText($tempPath, (ConvertTo-Json -InputObject $snapshot -Depth 6), [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tempPath -Destination $fullPath -Force
}

function Set-MockActivityOutput {
    <#
    .SYNOPSIS
        Turns the line each mock call prints on or off, and sets its indent.
    .PARAMETER Indent
        Spaces before each line, so the lines can sit under a heading, such as
        the worker they belong to.
    .EXAMPLE
        Set-MockActivityOutput -Enabled $false
    .EXAMPLE
        Set-MockActivityOutput -Enabled $true -Indent 14
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $Enabled,
        [ValidateRange(0, 40)] [int] $Indent = 0
    )

    $script:ShowActivity   = $Enabled
    $script:ActivityIndent = $Indent
}
#endregion

#region Microsoft Graph
function Connect-MgGraph {
    <#
    .SYNOPSIS
        Mock of Connect-MgGraph. Marks Microsoft Graph as connected.
    .DESCRIPTION
        Accepts the parameters production code would use, such as -Identity
        for a managed identity, and ignores their values. No credentials are
        checked or stored.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Scopes,
        [switch] $Identity,
        [string] $ClientId,
        [string] $TenantId,
        [string] $CertificateThumbprint,
        [switch] $NoWelcome
    )

    Assert-MockInitialized
    $script:Connected['Graph'] = $true
    $method = if ($Identity) { 'managed identity' } elseif ($CertificateThumbprint) { 'certificate' } else { 'delegated sign-in' }
    Write-MockActivity -Source 'Entra' -Colour Green -Message "Connected to Microsoft Graph using $method"
}

function Disconnect-MgGraph {
    <#
    .SYNOPSIS
        Mock of Disconnect-MgGraph.
    #>
    [CmdletBinding()]
    param()

    $script:Connected['Graph'] = $false
    Write-MockActivity -Source 'Entra' -Message 'Disconnected from Microsoft Graph'
}

function Get-MgUser {
    <#
    .SYNOPSIS
        Mock of Get-MgUser. Gets one user by -UserId, or lists users.
    .DESCRIPTION
        -UserId accepts an object ID or userPrincipalName and fails with 404
        when there is no such user. -Filter supports the one query the sync
        needs, "employeeId eq 'E1001'", matched exactly; returns nothing when
        there is no match and every match when the directory is ambiguous.
        -ExpandProperty manager fills in Manager. -ConsistencyLevel,
        -CountVariable and -Property are accepted for compatibility.
    .EXAMPLE
        Get-MgUser -Filter "employeeId eq 'E9013'" -ExpandProperty manager
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Get')] [string] $UserId,
        [Parameter(ParameterSetName = 'List')] [string] $Filter,
        [Parameter(ParameterSetName = 'List')] [switch] $All,
        [Parameter(ParameterSetName = 'List')] [string] $ConsistencyLevel,
        [Parameter(ParameterSetName = 'List')] [string] $CountVariable,
        [string[]] $Property,
        [string[]] $ExpandProperty
    )

    Assert-MockConnected -Service 'Graph'
    $expandManager = $ExpandProperty -contains 'manager'

    if ($PSCmdlet.ParameterSetName -eq 'Get') {
        Write-MockActivity -Source 'Entra' -Message "Getting user $UserId"
        $user = Find-StoredUser -Identity $UserId
        if ($null -eq $user) {
            throw (New-MockHttpError -Source 'Entra' -StatusCode 404 -Message "Resource '$UserId' does not exist or one of its queried reference-property objects are not present.")
        }
        Invoke-ConfiguredFailure -Source 'Entra' -Section 'entra' -EmployeeId $user.employeeId
        Write-MockActivity -Source 'Entra' -Colour Green -Message "Found user $($user.employeeId) $($user.displayName)"
        return ConvertTo-MgUserObject -User $user -ExpandManager:$expandManager
    }

    if ($Filter) {
        $filterMatch = [regex]::Match($Filter, "^employeeId eq '([^']*)'$")
        if (-not $filterMatch.Success) {
            throw (New-MockHttpError -Source 'Entra' -StatusCode 400 -Message "the mock only supports -Filter `"employeeId eq '...'`"")
        }
        $employeeId = $filterMatch.Groups[1].Value
        Write-MockActivity -Source 'Entra' -Message "Looking up users with employeeId $employeeId"
        Invoke-ConfiguredFailure -Source 'Entra' -Section 'entra' -EmployeeId $employeeId
        $found = @($script:State.Users | Where-Object { [string] (Get-MockValue $_ 'employeeId') -ceq $employeeId })

        $colour = switch ($found.Count) { 0 { 'DarkGray' } 1 { 'Green' } default { 'Yellow' } }
        Write-MockActivity -Source 'Entra' -Colour $colour -Message ('Found {0} user(s) with employeeId {1}' -f $found.Count, $employeeId)
    }
    else {
        $found = @($script:State.Users)
        Write-MockActivity -Source 'Entra' -Colour Green -Message "Listed all $($found.Count) users"
    }

    foreach ($user in $found) {
        ConvertTo-MgUserObject -User $user -ExpandManager:$expandManager
    }
}

function New-MgUser {
    <#
    .SYNOPSIS
        Mock of New-MgUser. Creates a user and starts provisioning their mailbox.
    .DESCRIPTION
        As in the real service, AccountEnabled, DisplayName, MailNickname,
        UserPrincipalName and PasswordProfile are required (400 if missing),
        and the userPrincipalName must be unique (400 if taken). Values can be
        passed as parameters or in -BodyParameter.

        The new user has no Mail yet. Exchange assigns the primary SMTP
        address from MailNickname; Get-EXOMailbox shows it once the mailbox
        has been provisioned, and the user's Mail is set then. A manager is
        not set here; use Set-MgUserManagerByRef, as with the real service.
    .EXAMPLE
        New-MgUser -AccountEnabled -DisplayName 'Alex Clarke' -GivenName Alex -Surname Clarke `
            -Department Quality -EmployeeId E9013 -MailNickname alex.clarke `
            -UserPrincipalName E9013@example.com -PasswordProfile @{ Password = '...'; ForceChangePasswordNextSignIn = $true }
    #>
    [CmdletBinding()]
    param(
        [switch] $AccountEnabled,
        [string] $DisplayName,
        [string] $GivenName,
        [string] $Surname,
        [string] $Department,
        [string] $EmployeeId,
        [string] $MailNickname,
        [string] $UserPrincipalName,
        [hashtable] $PasswordProfile,
        [hashtable] $BodyParameter
    )

    Assert-MockConnected -Service 'Graph'

    # Collect the values, from -BodyParameter first and then from named
    # parameters, which win. The password is kept out of everything printed.
    $values = @{}
    if ($BodyParameter) { foreach ($key in $BodyParameter.Keys) { $values[$key] = $BodyParameter[$key] } }
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'BodyParameter') { $values[$key] = $PSBoundParameters[$key] }
    }
    if ($values.ContainsKey('AccountEnabled')) { $values['AccountEnabled'] = [bool] $values['AccountEnabled'] }

    $employee = [string] $values['EmployeeId']
    Write-MockActivity -Source 'Entra' -Message "Creating user $employee ($($values['UserPrincipalName']))"
    Invoke-ConfiguredFailure -Source 'Entra' -Section 'entra' -EmployeeId $employee

    $missing = @('AccountEnabled', 'DisplayName', 'MailNickname', 'UserPrincipalName', 'PasswordProfile') |
        Where-Object { -not $values.ContainsKey($_) -or ($null -eq $values[$_]) -or ([string] $values[$_] -eq '') }
    if (@($missing).Count -gt 0) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 400 -Message "Property '$(@($missing)[0])' is required when creating the user.")
    }
    if (-not (Get-MockValue $values['PasswordProfile'] 'Password')) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 400 -Message 'PasswordProfile must include a Password.')
    }
    if (Find-StoredUser -Identity $values['UserPrincipalName']) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 400 -Message 'Another object with the same value for property userPrincipalName already exists.')
    }

    $user = [pscustomobject]@{
        id                = [guid]::NewGuid().ToString()
        employeeId        = $employee
        accountEnabled    = $values['AccountEnabled']
        displayName       = $values['DisplayName']
        givenName         = $values['GivenName']
        surname           = $values['Surname']
        department        = $values['Department']
        managerEmployeeId = $null
        mail              = $null
        userPrincipalName = $values['UserPrincipalName']
        mailNickname      = $values['MailNickname']
    }
    $script:State.Users.Add($user)

    # Exchange reserves the address now, but the mailbox is only found once provisioned.
    $script:State.Mailboxes[$user.id] = @{
        EmployeeId = $employee
        Address    = Get-AssignedAddress -MailNickname $values['MailNickname']
        Checks     = 0
        Ready      = $false
    }

    Write-MockActivity -Source 'Entra' -Colour Green -Message (
        'Created user {0} {1}, object ID {2}, enabled: {3}' -f $employee, $user.displayName, $user.id, $user.accountEnabled)
    Write-MockActivity -Source 'Exchange' -Colour Yellow -Message "Mailbox provisioning started for $employee; Get-EXOMailbox will not find it until it is ready"
    ConvertTo-MgUserObject -User $user
}

function Update-MgUser {
    <#
    .SYNOPSIS
        Mock of Update-MgUser. Changes properties on an existing user.
    .DESCRIPTION
        Only the properties passed in are changed, as named parameters or in
        -BodyParameter. Returns nothing, like the real command. Fails with 404
        for an unknown user.
    .EXAMPLE
        Update-MgUser -UserId $user.Id -Department Finance
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserId,
        [string] $Department,
        [switch] $AccountEnabled,
        [string] $GivenName,
        [string] $Surname,
        [string] $DisplayName,
        [hashtable] $BodyParameter
    )

    Assert-MockConnected -Service 'Graph'
    Write-MockActivity -Source 'Entra' -Message "Updating user $UserId"

    $user = Find-StoredUser -Identity $UserId
    if ($null -eq $user) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 404 -Message "Resource '$UserId' does not exist or one of its queried reference-property objects are not present.")
    }
    Invoke-ConfiguredFailure -Source 'Entra' -Section 'entra' -EmployeeId $user.employeeId

    $values = @{}
    if ($BodyParameter) { foreach ($key in $BodyParameter.Keys) { $values[$key] = $BodyParameter[$key] } }
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -notin 'UserId', 'BodyParameter') { $values[$key] = $PSBoundParameters[$key] }
    }

    $changes = foreach ($key in $values.Keys) {
        # Stored property names are camelCase, as in the mock files.
        $name  = $key.Substring(0, 1).ToLowerInvariant() + $key.Substring(1)
        $value = if ($name -eq 'accountEnabled') { [bool] $values[$key] } else { $values[$key] }
        $from  = Get-MockValue $user $name
        $user | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
        '{0}: {1} -> {2}' -f $name, $from, $value
    }
    Write-MockActivity -Source 'Entra' -Colour Green -Message ('Updated user {0}: {1}' -f $user.employeeId, (@($changes) -join ', '))
}

function Set-MgUserManagerByRef {
    <#
    .SYNOPSIS
        Mock of Set-MgUserManagerByRef. Sets a user's manager.
    .DESCRIPTION
        The manager is given as a directory reference, as with the real
        command: -OdataId or -BodyParameter @{ '@odata.id' = '.../users/<id>' }.
        Fails with 404 when the user or the manager does not exist.
    .EXAMPLE
        Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserId,
        [string] $OdataId,
        [hashtable] $BodyParameter
    )

    Assert-MockConnected -Service 'Graph'

    $reference = if ($OdataId) { $OdataId } else { Get-MockValue $BodyParameter '@odata.id' }
    if ([string]::IsNullOrWhiteSpace($reference)) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 400 -Message "a manager reference ('@odata.id') is required")
    }
    $managerObjectId = ($reference -split '/')[-1]

    $user    = Find-StoredUser -Identity $UserId
    $manager = Find-StoredUser -Identity $managerObjectId
    if ($null -eq $user) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 404 -Message "Resource '$UserId' does not exist.")
    }
    if ($null -eq $manager) {
        throw (New-MockHttpError -Source 'Entra' -StatusCode 404 -Message "Resource '$managerObjectId' does not exist.")
    }
    Invoke-ConfiguredFailure -Source 'Entra' -Section 'entra' -EmployeeId $user.employeeId

    $from = Get-MockValue $user 'managerEmployeeId'
    if (-not $from) { $from = '(none)' }
    $user | Add-Member -NotePropertyName managerEmployeeId -NotePropertyValue $manager.employeeId -Force
    Write-MockActivity -Source 'Entra' -Colour Green -Message ('Set manager of {0}: {1} -> {2}' -f $user.employeeId, $from, $manager.employeeId)
}
#endregion

#region Exchange Online
function Connect-ExchangeOnline {
    <#
    .SYNOPSIS
        Mock of Connect-ExchangeOnline. Marks Exchange Online as connected.
    .DESCRIPTION
        Accepts the parameters production code would use, such as
        -ManagedIdentity and -Organization, and ignores their values.
    #>
    [CmdletBinding()]
    param(
        [switch] $ManagedIdentity,
        [string] $Organization,
        [string] $AppId,
        [string] $CertificateThumbprint,
        [bool] $ShowBanner = $true
    )

    Assert-MockInitialized
    $script:Connected['Exchange'] = $true
    $method = if ($ManagedIdentity) { 'managed identity' } elseif ($CertificateThumbprint) { 'certificate' } else { 'delegated sign-in' }
    Write-MockActivity -Source 'Exchange' -Colour Green -Message "Connected to Exchange Online using $method"
}

function Disconnect-ExchangeOnline {
    <#
    .SYNOPSIS
        Mock of Disconnect-ExchangeOnline.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $script:Connected['Exchange'] = $false
    Write-MockActivity -Source 'Exchange' -Message 'Disconnected from Exchange Online'
}

function Get-EXOMailbox {
    <#
    .SYNOPSIS
        Mock of Get-EXOMailbox. Gets a mailbox and its primary SMTP address.
    .DESCRIPTION
        -Identity accepts the user's object ID, userPrincipalName or email.
        As with the real command, a mailbox that is still being provisioned
        is simply not found: the call fails with 404 until the mailbox has
        been checked readyAfterChecks times (from the behaviour file, default
        2). A mailbox listed in neverReady is never found. Once found, the
        user's Mail is set to the PrimarySmtpAddress Exchange assigned.
    .EXAMPLE
        (Get-EXOMailbox -Identity $user.Id).PrimarySmtpAddress
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Identity,
        [string[]] $Properties
    )

    Assert-MockConnected -Service 'Exchange'

    $notFound = "The operation couldn't be performed because object '$Identity' couldn't be found."
    $user     = Find-StoredUser -Identity $Identity
    $mailbox  = if ($user) { $script:State.Mailboxes[$user.id] }
    if ($null -eq $mailbox) {
        throw (New-MockHttpError -Source 'Exchange' -StatusCode 404 -Message $notFound)
    }

    $exchange   = Get-MockValue $script:State.Behaviour 'exchange'
    $readyAfter = Get-MockValue $exchange 'readyAfterChecks'
    if ($null -eq $readyAfter) { $readyAfter = 2 }
    $neverReady = @(Get-MockValue $exchange 'neverReady') -ccontains $mailbox.EmployeeId

    $mailbox.Checks++
    $wasReady = $mailbox.Ready
    if (-not $mailbox.Ready -and -not $neverReady -and ($mailbox.Checks -ge [int] $readyAfter)) {
        $mailbox.Ready = $true
        $user.mail     = $mailbox.Address
    }

    # Not provisioned yet: report it in yellow, since it is expected, then fail as the real command does.
    $employeeId = $mailbox.EmployeeId
    if (-not $mailbox.Ready) {
        $detail = if ($neverReady) { "check $($mailbox.Checks); set never to be provisioned" } else { "check $($mailbox.Checks) of $readyAfter" }
        Write-MockActivity -Source 'Exchange' -Colour Yellow -Message "Mailbox for $employeeId not found yet; still provisioning ($detail)"
        throw (New-MockHttpError -Source 'Exchange' -StatusCode 404 -Message $notFound -Silent)
    }

    if ($wasReady) {
        Write-MockActivity -Source 'Exchange' -Colour Green -Message "Mailbox for $employeeId found: $($mailbox.Address)"
    }
    else {
        Write-MockActivity -Source 'Exchange' -Colour Green -Message "Mailbox for $employeeId is now provisioned: $($mailbox.Address) (check $($mailbox.Checks))"
    }

    [pscustomobject]@{
        PSTypeName                = 'Deserialized.Microsoft.Exchange.Data.Directory.Management.Mailbox'
        Identity                  = $user.id
        DisplayName               = Get-MockValue $user 'displayName'
        UserPrincipalName         = Get-MockValue $user 'userPrincipalName'
        PrimarySmtpAddress        = $mailbox.Address
        ExternalDirectoryObjectId = $user.id
        RecipientTypeDetails      = 'UserMailbox'
    }
}
#endregion

#region HRIS
function Get-HRISWorker {
    <#
    .SYNOPSIS
        Reads one HRIS worker by employeeId.
    .DESCRIPTION
        Throws 401 without a valid token, 404 when no worker has the
        employeeId, and 409 when more than one does.
    .EXAMPLE
        Get-HRISWorker -EmployeeId E9013 -Token $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EmployeeId,
        [string] $Token
    )

    Write-MockActivity -Source 'HRIS' -Message "Reading worker $EmployeeId"
    Assert-HRISToken -Token $Token
    $worker = Get-HRISWorkerRecord -EmployeeId $EmployeeId

    $email = Get-MockValue $worker 'email'
    $shown = if ($email) { $email } else { '(none)' }
    Write-MockActivity -Source 'HRIS' -Colour Green -Message "Read worker $EmployeeId; email: $shown"
    $worker.PSObject.Copy()
}

function Set-HRISWorkerEmail {
    <#
    .SYNOPSIS
        Writes a confirmed email address to one HRIS worker, by employeeId.
    .DESCRIPTION
        Checks are made in this order:
          1. Token missing or wrong                   -> 401
          2. employeeId, email or idempotency key     -> 400
             missing or malformed
          3. Idempotency key already used            -> the stored result again,
                                                         with Replayed = true
                                                         (422 if it was used for
                                                         a different request)
          4. Failure configured for this employeeId  -> that failure (e.g. 503)
          5. No worker, or more than one              -> 404 / 409
          6. Worker already has this address          -> Result NoChange
          7. Worker has a different address           -> 409, never overwritten
          8. Worker has no address                    -> written, Result Updated
    .PARAMETER IdempotencyKey
        A key unique to this write, such as "E9013:alex.clarke@example.com".
        Sending the same request again with the same key is harmless.
    .EXAMPLE
        Set-HRISWorkerEmail -EmployeeId E9013 -Email alex.clarke@example.com -IdempotencyKey 'E9013:alex.clarke@example.com' -Token $token
    #>
    [CmdletBinding()]
    param(
        [string] $EmployeeId,
        [string] $Email,
        [string] $IdempotencyKey,
        [string] $Token
    )

    Write-MockActivity -Source 'HRIS' -Message "Writing email '$Email' to worker $EmployeeId (idempotency key '$IdempotencyKey')"

    # 1. Authentication comes before anything else is looked at.
    Assert-HRISToken -Token $Token

    # 2. Input validation.
    if ($EmployeeId -cnotmatch '^E\d+$') {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 400 -Message 'employeeId is missing or malformed')
    }
    if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 400 -Message 'email is missing or malformed')
    }
    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 400 -Message 'an idempotency key is required')
    }

    # 3. A repeated request returns the first result without applying it again.
    $request = "$EmployeeId|$Email"
    if ($script:State.IdempotentResults.ContainsKey($IdempotencyKey)) {
        $stored = $script:State.IdempotentResults[$IdempotencyKey]
        if ($stored.Request -cne $request) {
            throw (New-MockHttpError -Source 'HRIS' -StatusCode 422 -Message 'idempotency key was already used for a different request')
        }
        $replay = $stored.Result.PSObject.Copy()
        $replay.Replayed = $true
        Write-MockActivity -Source 'HRIS' -Colour Cyan -Message "Same request seen before; returning the earlier result ($($replay.Result)) without writing again"
        return $replay
    }

    # 4. Simulated failure for this employeeId.
    Invoke-ConfiguredFailure -Source 'HRIS' -Section 'HRIS' -EmployeeId $EmployeeId

    # 5. Find exactly one worker.
    $worker  = Get-HRISWorkerRecord -EmployeeId $EmployeeId
    $current = [string] (Get-MockValue $worker 'email')

    # 6 to 8. Email addresses are compared without regard to case.
    if ($current -eq $Email) {
        $resultName = 'NoChange'
        Write-MockActivity -Source 'HRIS' -Colour DarkGray -Message "Worker $EmployeeId already has $Email; nothing written"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($current)) {
        throw (New-MockHttpError -Source 'HRIS' -StatusCode 409 -Message "worker $EmployeeId already has a different email address ($current); not overwritten")
    }
    else {
        $worker.email = $Email
        $resultName   = 'Updated'
        Write-MockActivity -Source 'HRIS' -Colour Green -Message "Wrote $Email to worker $EmployeeId"
    }

    $result = [pscustomobject]@{
        EmployeeId = $EmployeeId
        Email      = $Email
        Result     = $resultName
        Replayed   = $false
    }
    $script:State.IdempotentResults[$IdempotencyKey] = @{ Request = $request; Result = $result }
    $result
}
#endregion

Export-ModuleMember -Function Initialize-MockServices, Save-MockServices, Set-MockActivityOutput,
    Connect-MgGraph, Disconnect-MgGraph, Get-MgUser, New-MgUser, Update-MgUser, Set-MgUserManagerByRef,
    Connect-ExchangeOnline, Disconnect-ExchangeOnline, Get-EXOMailbox,
    Get-HRISWorker, Set-HRISWorkerEmail
