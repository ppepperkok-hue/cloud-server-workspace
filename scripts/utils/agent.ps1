<#
.SYNOPSIS
    Dot-sourceable client for the ops-agent running on bt-he1k.

.DESCRIPTION
    scripts/deploy/install-ops-agent.sh installs a loopback-only HTTP service on the
    server (127.0.0.1:7777); scripts/utils/napcat-webui-tunnel.ps1 forwards that port to
    this machine. This file is the fast path: dot-source it and call the functions, so a
    remote command costs one localhost HTTP round trip (~120 ms warm) instead of a fresh
    ssh.exe handshake plus PowerShell argv mangling (~1700 ms).

    Because the command travels as JSON, quotes, pipes, redirects, `{{...}}` docker
    format strings and multi-line scripts all work - none of the ssh.exe argv traps
    apply here. Prefer this over scripts/utils/ssh-bt-he1k.ps1 for anything routine;
    keep the SSH wrapper for bootstrapping (the agent is not up yet) and for when the
    tunnel is down.

    The bearer token is read from secrets/ops-agent-token.txt (gitignored) and is never
    printed. Functions print stdout/stderr and set $LASTEXITCODE to the remote exit
    code; add -PassThru to get the raw result object instead.

.EXAMPLE
    . D:\cloud-server-workspace\scripts\utils\agent.ps1
    AgentRun 'uptime -p'
    AgentRun "docker ps --format 'table {{.Names}}\t{{.Status}}'"
    AgentScript -Path .\tmp\check.sh -Arguments one, two
    $id = AgentSpawn 'dnf -y update'; AgentJob -Id $id -Wait
#>

$script:OpsAgentBaseUrl = 'http://127.0.0.1:7777'
$script:OpsAgentToken = $null

function Get-OpsAgentToken {
    if ($script:OpsAgentToken) { return $script:OpsAgentToken }
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $path = Join-Path $root 'secrets\ops-agent-token.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Token not found: $path. Install the agent with scripts/deploy/install-ops-agent.sh and save its token there (see docs/runbooks/ops-agent.md)."
    }
    $token = ([System.IO.File]::ReadAllText($path)).Trim()
    if ($token.Length -lt 32) { throw "Token in $path looks too short." }
    $script:OpsAgentToken = $token
    return $token
}

function Invoke-OpsAgent {
    [CmdletBinding()]
    param(
        [string]$Method = 'GET',
        [string]$Route = '/health',
        $Payload = $null,
        [int]$TimeoutSec = 300
    )
    $req = @{
        Uri             = $script:OpsAgentBaseUrl + $Route
        Method          = $Method
        Headers         = @{ Authorization = "Bearer $(Get-OpsAgentToken)" }
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }
    if ($null -ne $Payload) {
        $req['Body'] = [System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 8 -Compress))
        $req['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        $resp = Invoke-WebRequest @req
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Unable to connect|actively refused|远程主机强迫关闭|连接') {
            throw "Cannot reach the ops-agent at $($script:OpsAgentBaseUrl): is the SSH tunnel up? Start .\scripts\utils\napcat-webui-tunnel.ps1. ($msg)"
        }
        throw
    }
    return ($resp.Content | ConvertFrom-Json)
}

function Write-OpsAgentResult {
    [CmdletBinding()]
    param($Result, [string]$Label = '')
    # NOTE: this function must never *return* anything. It used to `return` the exit
    # code, which made callers' `$code = Write-OpsAgentResult ...` swallow every line of
    # stdout into the variable instead of printing it (silent empty output). The exit
    # code is read separately with Get-OpsAgentExitCode.
    if ($Result.stdout) { Write-Output ($Result.stdout -replace "`r`n", "`n").TrimEnd("`n") }
    if ($Result.stderr) {
        foreach ($line in (($Result.stderr -replace "`r`n", "`n").TrimEnd("`n") -split "`n")) {
            Write-Output "stderr| $line"
        }
    }
    if ($Result.PSObject.Properties.Name -contains 'timeout' -and $Result.timeout) {
        Write-Output "TIMEOUT ($Label) - the command exceeded its timeout and was killed"
    }
    if ($Result.stdout_truncated) { Write-Warning 'stdout was truncated to the last 1 MiB by the agent' }
    if ($Result.stderr_truncated) { Write-Warning 'stderr was truncated to the last 1 MiB by the agent' }
}

function Get-OpsAgentExitCode {
    [CmdletBinding()]
    param($Result)
    if ($Result.PSObject.Properties.Name -contains 'timeout' -and $Result.timeout) { return 124 }
    if ($Result.PSObject.Properties.Name -contains 'exit' -and $null -ne $Result.exit) { return [int]$Result.exit }
    return 0
}

function AgentRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Cmd,
        [int]$TimeoutSec = 300,
        [string]$Cwd,
        [switch]$PassThru,
        [switch]$Quiet
    )
    $payload = @{ cmd = $Cmd; timeout = $TimeoutSec }
    if ($Cwd) { $payload['cwd'] = $Cwd }
    $r = Invoke-OpsAgent -Method POST -Route '/run' -Payload $payload -TimeoutSec ($TimeoutSec + 30)
    if ($PassThru) { return $r }
    Write-OpsAgentResult -Result $r -Label $Cmd
    if (-not $Quiet) { $global:LASTEXITCODE = Get-OpsAgentExitCode -Result $r }
}

function AgentScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 300,
        [string]$Cwd,
        [switch]$PassThru,
        [switch]$Quiet
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Script not found: $Path" }
    $text = (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path) -replace "`r`n", "`n"
    $payload = @{ script = $text; args = @($Arguments); name = (Split-Path -Leaf $Path); timeout = $TimeoutSec }
    if ($Cwd) { $payload['cwd'] = $Cwd }
    $r = Invoke-OpsAgent -Method POST -Route '/script' -Payload $payload -TimeoutSec ($TimeoutSec + 30)
    if ($PassThru) { return $r }
    Write-OpsAgentResult -Result $r -Label $Path
    if (-not $Quiet) { $global:LASTEXITCODE = Get-OpsAgentExitCode -Result $r }
}

function AgentSpawn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Cmd,
        [int]$TimeoutSec = 7200,
        [string]$Cwd
    )
    $payload = @{ cmd = $Cmd; timeout = $TimeoutSec }
    if ($Cwd) { $payload['cwd'] = $Cwd }
    $r = Invoke-OpsAgent -Method POST -Route '/spawn' -Payload $payload
    return $r.id
}

function AgentJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Id,
        [switch]$Wait,
        [int]$PollSeconds = 5,
        [int]$MaxSeconds = 1800,
        [switch]$PassThru
    )
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    while ($true) {
        $r = Invoke-OpsAgent -Method GET -Route "/job?id=$Id"
        if (-not $Wait -or $r.state -ne 'running' -or (Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }
    if ($PassThru) { return $r }
    if ($r.state -eq 'running') {
        Write-Output "job $($r.id) still running: $($r.cmd)"
        $global:LASTEXITCODE = 0
        return
    }
    Write-Output ("job {0} {1} in {2}ms: {3}" -f $r.id, $r.state, [int]($r.duration_ms), $r.cmd)
    Write-OpsAgentResult -Result $r -Label $r.cmd
    $global:LASTEXITCODE = Get-OpsAgentExitCode -Result $r
}

function AgentJobs {
    [CmdletBinding()] param()
    $r = Invoke-OpsAgent -Method GET -Route '/jobs'
    if (-not $r.jobs -or $r.jobs.Count -eq 0) { Write-Output 'no jobs'; return }
    foreach ($j in $r.jobs) {
        Write-Output ("{0}  {1,-8} exit={2,-5} {3}" -f $j.id, $j.state, $j.exit, $j.cmd)
    }
}

function AgentHealth {
    [CmdletBinding()] param()
    $r = Invoke-OpsAgent -Method GET -Route '/health'
    Write-Output ("ops-agent {0} on {1} port {2}, python {3}, pid {4}, up {5}s" -f `
        $r.version, $r.host, $r.port, $r.python, $r.pid, $r.uptime_s)
}

function AgentPut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Local,
        [Parameter(Mandatory = $true, Position = 1)][string]$Remote,
        [string]$Mode = '644'
    )
    $full = (Resolve-Path -LiteralPath $Local).Path
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $r = Invoke-OpsAgent -Method POST -Route '/put' -Payload @{
        path = $Remote; content_b64 = [Convert]::ToBase64String($bytes); mode = $Mode
    }
    Write-Output ("uploaded {0} -> {1} ({2} bytes)" -f $Local, $r.path, $r.size)
}

function AgentGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Remote,
        [Parameter(Mandatory = $true, Position = 1)][string]$Local
    )
    $r = Invoke-OpsAgent -Method GET -Route ('/get?path=' + [uri]::EscapeDataString($Remote))
    $dir = Split-Path -Parent $Local
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Local, [Convert]::FromBase64String($r.data_b64))
    Write-Output ("downloaded {0} -> {1} ({2} bytes)" -f $r.path, $Local, $r.size)
}

function AgentLs {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Remote = '/root')
    $r = Invoke-OpsAgent -Method GET -Route ('/ls?path=' + [uri]::EscapeDataString($Remote))
    foreach ($e in $r.entries) {
        $kind = if ($e.dir) { 'd' } else { '-' }
        Write-Output ("{0} {1} {2,10}  {3}" -f $kind, $e.mode, $e.size, $e.name)
    }
}
