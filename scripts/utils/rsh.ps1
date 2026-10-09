<#
.SYNOPSIS
    Talk to the ops-agent on bt-he1k over the SSH tunnel (fast replacement for one-shot ssh).

.DESCRIPTION
    scripts/deploy/install-ops-agent.sh installs a loopback-only HTTP service on the
    server (127.0.0.1:7777) that runs commands, background jobs and file transfers.
    scripts/utils/napcat-webui-tunnel.ps1 forwards that port to this machine, so each
    call here is one localhost HTTP round trip instead of a fresh ssh.exe handshake.

    The bearer token is read from secrets/ops-agent-token.txt (gitignored) and is never
    printed. If the tunnel is down, every call fails with a connection error: start it
    with `.\scripts\utils\napcat-webui-tunnel.ps1`.

    $LASTEXITCODE is set to the remote command's exit code (0 for control commands).

.PARAMETER Command
    Shell command to run on the server (bash -lc).

.PARAMETER ScriptPath
    Local bash script to run on the server. Shipped as text, so there is no size limit
    and no CRLF/quoting problem.

.PARAMETER Spawn
    Run a command in the background on the server; prints the job id.

.PARAMETER Job
    Fetch one background job's status and output.

.PARAMETER WaitJob
    Poll a background job until it is done, then print it.

.PARAMETER Jobs
    List background jobs.

.PARAMETER Health
    Print agent health/version.

.PARAMETER Put
    Upload a local file. Needs -RemotePath.

.PARAMETER Get
    Download a remote file. Needs -LocalPath.

.EXAMPLE
    .\scripts\utils\rsh.ps1 -Command 'uptime; systemctl is-active docker'

.EXAMPLE
    .\scripts\utils\rsh.ps1 -ScriptPath .\tmp\check.sh -ScriptArgs one two

.EXAMPLE
    .\scripts\utils\rsh.ps1 -Spawn 'dnf -y update' ; .\scripts\utils\rsh.ps1 -WaitJob <id>
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Mandatory = $true, Position = 0)]
    [string]$Command,

    [Parameter(ParameterSetName = 'Script', Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter(ParameterSetName = 'Script')]
    [string[]]$ScriptArgs = @(),

    [Parameter(ParameterSetName = 'Spawn', Mandatory = $true)]
    [string]$Spawn,

    [Parameter(ParameterSetName = 'Job', Mandatory = $true)]
    [string]$Job,

    [Parameter(ParameterSetName = 'Job', Mandatory = $true)]
    [switch]$WaitJob,

    [Parameter(ParameterSetName = 'Jobs', Mandatory = $true)]
    [switch]$Jobs,

    [Parameter(ParameterSetName = 'Health', Mandatory = $true)]
    [switch]$Health,

    [Parameter(ParameterSetName = 'Put', Mandatory = $true)]
    [string]$Put,

    [Parameter(ParameterSetName = 'Put', Mandatory = $true)]
    [string]$RemotePath,

    [Parameter(ParameterSetName = 'Get', Mandatory = $true)]
    [string]$Get,

    [Parameter(ParameterSetName = 'Get', Mandatory = $true)]
    [string]$LocalPath,

    [int]$TimeoutSec = 300,

    [string]$AgentHost = '127.0.0.1',

    [int]$Port = 7777,

    [string]$BaseUrl,

    [switch]$Json,

    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tokenPath = Join-Path $repoRoot 'secrets\ops-agent-token.txt'

if (-not (Test-Path -LiteralPath $tokenPath)) {
    throw "Token not found: $tokenPath. Run scripts/deploy/install-ops-agent.sh first (see docs/runbooks/ops-agent.md)."
}
$token = ([System.IO.File]::ReadAllText($tokenPath)).Trim()
if ($token.Length -lt 32) { throw "Token in $tokenPath looks too short." }

if (-not $BaseUrl) { $BaseUrl = "http://${AgentHost}:$Port" }
$headers = @{ Authorization = "Bearer $token" }

function Invoke-Agent {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Route,
        $Payload,
        [int]$RequestTimeout = 0
    )
    $req = @{
        Uri             = "$BaseUrl$Route"
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
        TimeoutSec      = if ($RequestTimeout -gt 0) { $RequestTimeout } else { $TimeoutSec + 30 }
    }
    if ($null -ne $Payload) {
        $json = $Payload | ConvertTo-Json -Depth 8 -Compress
        $req['Body']        = [System.Text.Encoding]::UTF8.GetBytes($json)
        $req['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        $resp = Invoke-WebRequest @req
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Unable to connect|actively refused|连接') {
            throw "Cannot reach the ops-agent at $BaseUrl. Is the SSH tunnel running? Start .\scripts\utils\napcat-webui-tunnel.ps1. ($msg)"
        }
        throw
    }
    return ($resp.Content | ConvertFrom-Json)
}

function Write-Result {
    param($Result, [string]$Label)
    if ($Json) { $Result | ConvertTo-Json -Depth 8; return }
    if ($Result.stdout) { Write-Output ($Result.stdout -replace "`r`n", "`n").TrimEnd("`n") }
    if ($Result.stderr) {
        foreach ($line in (($Result.stderr -replace "`r`n", "`n").TrimEnd("`n") -split "`n")) {
            Write-Output "stderr| $line"
        }
    }
    if ($Result.PSObject.Properties.Name -contains 'exit' -and $null -ne $Result.exit) {
        $global:LASTEXITCODE = [int]$Result.exit
    }
    elseif ($Result.timeout) {
        Write-Output "TIMEOUT after ${TimeoutSec}s ($Label)"
        $global:LASTEXITCODE = 124
    }
    if ($Result.stdout_truncated) { Write-Output "note: stdout was truncated to the last 1 MiB by the agent" }
    if ($Result.stderr_truncated) { Write-Output "note: stderr was truncated to the last 1 MiB by the agent" }
}

switch ($PSCmdlet.ParameterSetName) {
    'Health' {
        $r = Invoke-Agent -Method GET -Route '/health'
        if ($Json) { $r | ConvertTo-Json -Depth 8 }
        else { Write-Output ("ops-agent {0} on {1} port {2}, python {3}, pid {4}, up {5}s" -f $r.version, $r.host, $r.port, $r.python, $r.pid, $r.uptime_s) }
        $global:LASTEXITCODE = 0
    }
    'Run' {
        $r = Invoke-Agent -Method POST -Route '/run' -Payload @{ cmd = $Command; timeout = $TimeoutSec }
        Write-Result -Result $r -Label $Command
    }
    'Script' {
        if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script not found: $ScriptPath" }
        $text = (Get-Content -Raw -Encoding UTF8 -LiteralPath $ScriptPath) -replace "`r`n", "`n"
        $r = Invoke-Agent -Method POST -Route '/script' -Payload @{
            script = $text
            args   = @($ScriptArgs)
            name   = (Split-Path -Leaf $ScriptPath)
            timeout = $TimeoutSec
        }
        Write-Result -Result $r -Label $ScriptPath
    }
    'Spawn' {
        $r = Invoke-Agent -Method POST -Route '/spawn' -Payload @{ cmd = $Spawn; timeout = $TimeoutSec }
        if ($Json) { $r | ConvertTo-Json -Depth 8 } else { Write-Output $r.id }
        $global:LASTEXITCODE = 0
    }
    'Job' {
        do {
            $r = Invoke-Agent -Method GET -Route ("/job?id=" + $Job)
            if ($r.state -eq 'running' -and $WaitJob) { Start-Sleep -Seconds $PollSeconds }
        } while ($r.state -eq 'running' -and $WaitJob)
        if ($Json) {
            $r | ConvertTo-Json -Depth 8
        }
        else {
            if ($r.state -eq 'running') {
                Write-Output ("job {0} still running: {1}" -f $r.id, $r.cmd)
            }
            else {
                Write-Output ("job {0} {1} in {2}ms: {3}" -f $r.id, $r.state, ([int]((($r.ended - $r.started)) * 1000)), $r.cmd)
            }
            Write-Result -Result $r -Label $r.cmd
        }
        $global:LASTEXITCODE = 0
    }
    'Jobs' {
        $r = Invoke-Agent -Method GET -Route '/jobs'
        if ($Json) { $r | ConvertTo-Json -Depth 8 }
        else {
            if (-not $r.jobs -or $r.jobs.Count -eq 0) { Write-Output "no jobs" }
            foreach ($j in $r.jobs) {
                Write-Output ("{0}  {1,-8} exit={2}  {3}" -f $j.id, $j.state, $j.exit, $j.cmd)
            }
        }
        $global:LASTEXITCODE = 0
    }
    'Put' {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Put))
        $r = Invoke-Agent -Method POST -Route '/put' -Payload @{
            path        = $RemotePath
            content_b64 = [Convert]::ToBase64String($bytes)
            mode        = '644'
        }
        if ($Json) { $r | ConvertTo-Json -Depth 8 } else { Write-Output ("uploaded {0} ({1} bytes) -> {2}" -f $Put, $r.size, $r.path) }
        $global:LASTEXITCODE = 0
    }
    'Get' {
        $route = "/get?path=" + [uri]::EscapeDataString($Get)
        $r = Invoke-Agent -Method GET -Route $route
        $bytes = [Convert]::FromBase64String($r.data_b64)
        $dir = Split-Path -Parent $LocalPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($LocalPath, $bytes)
        if ($Json) { $r | ConvertTo-Json -Depth 8 } else { Write-Output ("downloaded {0} ({1} bytes) -> {2}" -f $r.path, $r.size, $LocalPath) }
        $global:LASTEXITCODE = 0
    }
}
