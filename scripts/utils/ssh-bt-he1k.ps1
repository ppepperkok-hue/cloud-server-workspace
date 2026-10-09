<#
.SYNOPSIS
    Run a command (or a whole bash script) on the bt-he1k test server over SSH.

.DESCRIPTION
    Workspace wrapper around ssh.exe for host bt-he1k (<TEST_HOST_IP>).
    - Uses the local-only key at secrets/ssh/lighthouse-he1k.pem (never printed, never committed).
    - Pins IdentitiesOnly=yes so no other identity can burn MaxAuthTries.
    - Keeps known_hosts out of the repo (temp file), so no stray NUL/known_hosts artifacts.
    - With -ScriptPath the script is normalised to LF and shipped via base64 into `bash -s`,
      which avoids all Windows quoting/CRLF problems for multi-line remote scripts.

    The caller is responsible for the safety of whatever it runs: this helper does not
    add confirmation prompts. Destructive remote operations still require explicit user
    approval per AGENTS.md.

.PARAMETER Command
    Single remote shell command, e.g. 'uptime; hostname'.

.PARAMETER ScriptPath
    Path to a local bash script to execute on the remote host.

.PARAMETER User
    SSH user. Default root (the only user bound to the <TEST_USER> key on this host).

.EXAMPLE
    .\scripts\utils\ssh-bt-he1k.ps1 -Command 'uptime; hostname'

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\ssh-bt-he1k.ps1 -Command 'uptime; hostname'

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\ssh-bt-he1k.ps1 -ScriptPath .\scripts\healthcheck\server-inventory.sh

.NOTES
    This machine has Windows PowerShell 5.1 only (no pwsh), so the documented
    invocation uses powershell.exe with -ExecutionPolicy Bypass.

    Do NOT put embedded double quotes in -Command: PowerShell 5.1 does not
    escape them when rebuilding the child process command line, and the
    argument gets split ('A positional parameter cannot be found ...').
    Put anything with quotes into a script file and use -ScriptPath instead.
#>
[CmdletBinding(DefaultParameterSetName = 'Command')]
param(
    [Parameter(ParameterSetName = 'Command', Mandatory = $true, Position = 0)]
    [string]$Command,

    [Parameter(ParameterSetName = 'Script', Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter(ParameterSetName = 'Script')]
    [string[]]$ScriptArgs = @(),

    [string]$User = 'root',

    [string]$HostName = '<TEST_HOST_IP>'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$keyPath  = Join-Path $repoRoot 'secrets\ssh\lighthouse-he1k.pem'

# This repo is public, so the parameter default above is a redaction placeholder.
# The real values live in the gitignored secrets/redaction-map.json (_real_facts), which
# is where scripts/utils/redact-workspace.py takes them from. Resolving here means the
# script still runs with no arguments after a redaction pass.
function Resolve-WorkspacePlaceholder {
    param([string]$Value, [string]$Key)
    if ($Value -notmatch '^<.+>$') { return $Value }
    $mapPath = Join-Path $repoRoot 'secrets\redaction-map.json'
    if (-not (Test-Path -LiteralPath $mapPath)) {
        throw "HostName is still the placeholder '$Value' and $mapPath is missing. Pass -HostName explicitly."
    }
    $raw = [System.IO.File]::ReadAllText($mapPath)
    $m = [regex]::Match($raw, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]+)"')
    if (-not $m.Success) {
        throw "Could not find '$Key' in $mapPath. Pass -HostName explicitly."
    }
    return $m.Groups[1].Value
}

$HostName = Resolve-WorkspacePlaceholder -Value $HostName -Key 'public_ip'

if (-not (Test-Path -LiteralPath $keyPath)) {
    throw "SSH key not found: $keyPath (see docs/runbooks/connect-bt-he1k.md)"
}

$knownHosts = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh_known_hosts'

$sshArgs = @(
    '-i', $keyPath
    '-o', 'IdentitiesOnly=yes'
    '-o', 'BatchMode=yes'
    '-o', 'StrictHostKeyChecking=accept-new'
    '-o', "UserKnownHostsFile=$knownHosts"
    '-o', 'ConnectTimeout=15'
    '-o', 'LogLevel=ERROR'
)

if ($PSCmdlet.ParameterSetName -eq 'Script') {
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script not found: $ScriptPath" }

    # Ship the script as a gzip+base64 argv payload.
    # Measured on 2026-09-28, Windows PowerShell 5.1 + OpenSSH for Windows:
    #   * plain base64 of this script is ~9.2 KB, and ssh.exe silently drops the
    #     tail of argv past ~8 KB, so "| base64 -d | bash -s" never arrives and
    #     the remote just echoes the payload.
    #   * piping the script over ssh STDIN is worse: PowerShell rewrites LF to
    #     CRLF, bash sees stray "\r", and the call ends with exit code 127.
    # gzip+base64 is ~2.5x smaller and byte-exact. See ADR-0001.
    $text = (Get-Content -Raw -LiteralPath $ScriptPath) -replace "`r`n", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }

    $raw = [Text.Encoding]::UTF8.GetBytes($text)
    $ms  = New-Object System.IO.MemoryStream
    $gz  = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $gz.Write($raw, 0, $raw.Length)
    $gz.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose()

    if ($b64.Length -gt 7000) {
        throw ("Payload too large: {0} base64 chars (argv limit is ~8000). Split the script or copy it with scp - see docs/decisions/ADR-0001-windows-ssh-argv-limit.md" -f $b64.Length)
    }

    $remoteCommand = "echo $b64 | base64 -d | gunzip | bash -s $($ScriptArgs -join ' ')"
}
else {
    $remoteCommand = $Command
}

# Merge stderr into stdout and stringify it, then set $LASTEXITCODE instead of calling
# `exit`: a bare `exit` here would terminate the CALLER's PowerShell session whenever
# ssh returned non-zero, swallowing the caller's own follow-up output.
# $ErrorActionPreference must be Continue here or any stderr line from ssh (ssh.exe
# classifies remote stderr as a NativeCommandError) aborts the script under 'Stop'.
$ErrorActionPreference = 'Continue'
$all  = & ssh @sshArgs "$User@$HostName" $remoteCommand 2>&1
$code = $LASTEXITCODE
foreach ($item in $all) { Write-Output ([string]$item) }
$global:LASTEXITCODE = $code
