<#
.SYNOPSIS
    Open SSH tunnels to the bt-he1k admin UIs (NapCat WebUI x2) and keep them up.

.DESCRIPTION
    NapCat's WebUI is bound to 127.0.0.1 on the server, and exposing it publicly is
    both discouraged by the NapCat project and awkward here (Tencent Cloud intercepts
    port-80 HTTP whose Host is an unregistered domain - see ADR-0004). So the admin
    UIs are reached over an SSH tunnel instead: nothing new is exposed, and the traffic
    is encrypted.

    This forwards, from the machine you run it on:
        127.0.0.1:6099  ->  server 127.0.0.1:6099   (NapCat instance 1: QQ <QQ_ACCOUNT_A>)
        127.0.0.1:6100  ->  server 127.0.0.1:6100   (NapCat instance 2: QQ <QQ_ACCOUNT_B>)
        127.0.0.1:8000  ->  server 127.0.0.1:8000   (SillyTavern)
        127.0.0.1:6185  ->  server 127.0.0.1:6185   (AstrBot dashboard; HTTPS since 2026-10-09)
        127.0.0.1:7777  ->  server 127.0.0.1:7777   (ops-agent: the fast path for server commands)

    Leave this window open while you use the WebUIs; Ctrl+C closes the tunnels.

    The ops-agent tunnel is what makes `.\scripts\utils\agent.ps1` (or rsh.ps1) work:
    the agent only listens on the server's loopback, so every remote command needs this
    tunnel up. It costs ~124 ms per command instead of ~1700 ms for a fresh ssh.exe.
    See docs/decisions/ADR-0005-ops-agent.md and docs/runbooks/ops-agent.md.

.PARAMETER KeyPath
    SSH private key. Defaults to secrets/ssh/lighthouse-he1k.pem inside the workspace.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\napcat-webui-tunnel.ps1

.NOTES
    The AstrBot dashboard also has a public route (port 6185, HTTPS with the shared
    self-signed certificate; plain HTTP on 80 now redirects to 443) but it is far slower
    from outside than this tunnel, and the certificate is not trusted - prefer the tunnel.
#>
[CmdletBinding()]
param(
    [string]$KeyPath,
    [string]$HostName = '<TEST_HOST_IP>',
    [string]$User = 'root'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# This repo is public, so the parameter default above is a redaction placeholder.
# Resolve it from the gitignored secrets/redaction-map.json so the script still runs
# with no arguments after a redaction pass.
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

if (-not $KeyPath) {
    $KeyPath = Join-Path $repoRoot 'secrets\ssh\lighthouse-he1k.pem'
}
if (-not (Test-Path -LiteralPath $KeyPath)) {
    throw "SSH key not found: $KeyPath (see docs/runbooks/connect-bt-he1k.md)"
}

$knownHosts = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh_known_hosts'

# WebUI tokens are secrets: they live in the gitignored secrets/ folder, never in the
# script. Fetch them from the server with:
#   docker logs napcat1 | Select-String 'webui?token='
$tokenFile = Join-Path $repoRoot 'secrets\napcat-webui-tokens.json'
$tok1 = '<token>'
$tok2 = '<token>'
if (Test-Path -LiteralPath $tokenFile) {
    $json = Get-Content -Raw -LiteralPath $tokenFile | ConvertFrom-Json
    if ($json.'6099') { $tok1 = $json.'6099' }
    if ($json.'6100') { $tok2 = $json.'6100' }
}
else {
    Write-Warning "no $tokenFile - the URLs below will show '<token>'."
}

Write-Host ''
Write-Host '  NapCat + SillyTavern tunnels' -ForegroundColor Cyan
Write-Host ("    NapCat 1 (QQ account A) : http://127.0.0.1:6099/webui/?token={0}" -f $tok1)
Write-Host ("    NapCat 2 (QQ account B) : http://127.0.0.1:6100/webui/?token={0}" -f $tok2)
Write-Host  '    SillyTavern             : http://127.0.0.1:8000/  (the app itself is plain HTTP; TLS is terminated by nginx on 443)'
Write-Host  '    AstrBot dashboard       : https://127.0.0.1:6185/  (self-signed cert; the dashboard terminates TLS itself)'
Write-Host  '    ops-agent               : http://127.0.0.1:7777/health  (use .\scripts\utils\agent.ps1)'
Write-Host ''
Write-Host '  Public routes (slower, self-signed cert): https://<TEST_HOST_IP>/ (SillyTavern), https://<TEST_HOST_IP>:6185/ (AstrBot)' -ForegroundColor DarkGray
Write-Host '  Plain HTTP on port 80 now 301-redirects to 443. See ADR-0004 and KNOWN-ISSUES.' -ForegroundColor DarkGray
Write-Host '  Keep this window open. Ctrl+C to close the tunnels.' -ForegroundColor DarkGray
Write-Host ''

$sshArgs = @(
    '-i', $KeyPath
    '-o', 'IdentitiesOnly=yes'
    '-o', 'BatchMode=yes'
    '-o', 'StrictHostKeyChecking=accept-new'
    '-o', "UserKnownHostsFile=$knownHosts"
    '-o', 'ExitOnForwardFailure=yes'
    '-o', 'ServerAliveInterval=30'
    '-o', 'ServerAliveCountMax=3'
    '-N'
    '-L', '6099:127.0.0.1:6099'
    '-L', '6100:127.0.0.1:6100'
    '-L', '8000:127.0.0.1:8000'
    '-L', '6185:127.0.0.1:6185'
    '-L', '7777:127.0.0.1:7777'
    "$User@$HostName"
)

& ssh @sshArgs
exit $LASTEXITCODE
