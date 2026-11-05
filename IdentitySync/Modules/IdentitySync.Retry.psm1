<#
.SYNOPSIS
    Bounded retry with exponential back-off for calls to external services.

.DESCRIPTION
    Every call the sync makes to Microsoft Graph, Exchange Online and the
    HRIS goes through Invoke-WithRetry. A call that fails with a transient
    HTTP status (429 Too Many Requests, 502, 503 or 504) is tried again after
    a wait that doubles each time, plus a little random jitter so many
    workers do not all retry at the same moment. A 429 that says how long to
    wait (Retry-After) is respected. After MaxAttempts the last error is
    thrown, with Data['Attempts'] recording how many attempts were made.

    Any other failure (400, 401, 404, 409, or an error with no HTTP status)
    is thrown straight away: trying again would not help.

    The wait before attempt n+1 is:
        Retry-After, if the service gave one, otherwise
        BaseDelaySeconds * 2^(n-1) + jitter (0 to half of BaseDelaySeconds)
    and never more than MaxDelaySeconds. With the defaults (base 2 seconds,
    4 attempts) that is about 2, 4 and 8 seconds.

    Public functions:
      Invoke-WithRetry    Runs a script block, retrying transient failures.
#>

Set-StrictMode -Version Latest

# HTTP statuses that are worth retrying: throttling and temporary unavailability.
$script:TransientStatusCodes = @(429, 502, 503, 504)

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Runs a script block, retrying it on transient HTTP failures with back-off.
    .PARAMETER Action
        The call to make. Its output is returned.
    .PARAMETER Description
        What the call does, such as 'Get-MgUser E9013'. Passed to -OnRetry.
    .PARAMETER MaxAttempts
        Attempts in total, including the first. Defaults to 4.
    .PARAMETER BaseDelaySeconds
        The wait before the second attempt; it doubles after that. Defaults to 2.
    .PARAMETER MaxDelaySeconds
        The longest wait between attempts. Defaults to 30.
    .PARAMETER OnRetry
        Run before each wait, with one argument describing the retry:
        Description, Attempt, MaxAttempts, StatusCode, DelaySeconds, Message.
    .PARAMETER Sleep
        How to wait. Defaults to Start-Sleep; tests pass a stub that records
        the waits instead.
    .EXAMPLE
        Invoke-WithRetry -Description "Get-MgUser $id" -Action { Get-MgUser -Filter "employeeId eq '$id'" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [string] $Description = 'call',
        [ValidateRange(1, 20)] [int] $MaxAttempts = 4,
        [ValidateRange(0, 600)] [double] $BaseDelaySeconds = 2,
        [ValidateRange(0, 3600)] [double] $MaxDelaySeconds = 30,
        [scriptblock] $OnRetry,
        [scriptblock] $Sleep = { param($Seconds) Start-Sleep -Milliseconds ([int] ($Seconds * 1000)) }
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            $statusCode = [int] $_.Exception.Data['StatusCode']
            $transient  = $script:TransientStatusCodes -contains $statusCode

            # Not worth retrying, or out of attempts: record how many were made and stop.
            if (-not $transient -or $attempt -eq $MaxAttempts) {
                $_.Exception.Data['Attempts'] = $attempt
                throw
            }

            # Work out the wait: Retry-After if given, otherwise exponential back-off with jitter.
            $retryAfter = $_.Exception.Data['RetryAfterSeconds']
            if ($retryAfter) {
                $delay = [double] $retryAfter
            }
            else {
                $jitter = if ($BaseDelaySeconds -gt 0) { (Get-Random -Minimum 0.0 -Maximum 1.0) * ($BaseDelaySeconds / 2) } else { 0 }
                $delay  = ($BaseDelaySeconds * [math]::Pow(2, $attempt - 1)) + $jitter
            }
            $delay = [math]::Round([math]::Min($delay, $MaxDelaySeconds), 2)

            if ($OnRetry) {
                & $OnRetry ([pscustomobject]@{
                    Description  = $Description
                    Attempt      = $attempt
                    MaxAttempts  = $MaxAttempts
                    StatusCode   = $statusCode
                    DelaySeconds = $delay
                    Message      = $_.Exception.Message
                })
            }
            & $Sleep $delay
        }
    }
}

Export-ModuleMember -Function Invoke-WithRetry
