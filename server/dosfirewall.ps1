<#
    dosfirewall.ps1  --  let the DOS boxes reach dosd through Windows Firewall.

    WHY THIS EXISTS

    On 2026-09-21 both DOS machines went silent at once and stayed silent
    through a reboot and a power cycle. Neither was broken. The Windows
    firewall had stopped accepting their polls:

      * the LAN interface holding 192.168.1.10 was on the PRIVATE profile
      * the only Allow rules for python.exe were scoped to PUBLIC
      * DefaultInboundAction is NotConfigured, which means block

    so every poll was dropped before dosd could see it. The symptom is
    exactly the one this project keeps having to design against -- it looks
    like two hung DOS boxes, and the machines themselves look fine on their
    own screens, sitting in the offline retry loop with nothing to say.

    A network interface that disconnects and re-identifies can be re-filed
    under a different profile, which is what happened here: the
    NetworkProfile log shows the interface flapping, and the rules that had
    been working were attached to the profile it left.

    TWO MACHINES FAILING IDENTICALLY AT THE SAME MOMENT is the tell. They
    share exactly one thing, and it is this host. Before suspecting two
    independent DOS-side faults, check what is common to both.

    WHAT IT ADDS

    Port-scoped rules rather than a rule for python.exe, and limited to the
    subnet the boxes are on:

      UDP 8069           the transport: polls, files, results, pulls
      TCP 8080-8082      the CLI endpoint and the two legacy intakes

    Port rules survive a Python upgrade, which a program rule does not --
    and a program rule for python.exe opens every Python program on this
    machine, not just this one. `-RemoteAddress` keeps them off any other
    network this PC joins.

    Run it as Administrator:  dosfirewall.cmd
#>

[CmdletBinding()]
param(
    # The subnet the DOS boxes are on. Read from boxes.json when present.
    [string]$Subnet,
    # Which profiles to open. Private is the one that bit; Domain is
    # harmless to include and saves a second trip if the PC ever joins one.
    [string]$Profile = "Private,Domain",
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This needs Administrator -- firewall rules are machine-wide." -ForegroundColor Yellow
    Write-Host "Right-click dosfirewall.cmd and Run as administrator, or:"
    Write-Host "  Start-Process powershell -Verb RunAs -ArgumentList '-File','$PSCommandPath'"
    exit 1
}

if (-not $Subnet) {
    # Derive it from the registry rather than hardcoding: the addresses in
    # this project's notes are deliberately placeholders, and a script that
    # carried a real subnet would be wrong on anybody else's machine.
    $boxes = Join-Path $PSScriptRoot "boxes.json"
    $ip = $null
    if (Test-Path $boxes) {
        $cfg = Get-Content $boxes -Raw | ConvertFrom-Json
        $ip = ($cfg.boxes.PSObject.Properties |
               ForEach-Object { $_.Value.ip } |
               Where-Object { $_ -and $_ -ne "any" } |
               Select-Object -First 1)
    }
    if (-not $ip) {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object { $_.IPAddress -notlike '127.*' -and
                              $_.IPAddress -notlike '169.254.*' } |
               Select-Object -First 1).IPAddress
    }
    if (-not $ip) { throw "cannot work out which subnet to open" }
    $Subnet = ($ip -replace '\.\d+$', '.0') + "/24"
}

# The names start with "dosbridge" so server\check.py recognises them, and
# so they sort together in wf.msc. They were "DOS Bridge dosd (...)" first,
# and that space meant check.py's `-match 'dosbridge'` never matched: it
# reported a correctly opened firewall as unconfigured, from the one tool
# whose job is to tell you what is missing. check.py now accepts both forms
# as well, so an install that already has the old rules keeps working.
$rules = @(
    @{ Name = "dosbridge: TFTP transport (UDP 8069)";  Protocol = "UDP"; Port = "8069" },
    @{ Name = "dosbridge: CLI and intakes (TCP 8080-8082)"; Protocol = "TCP"; Port = "8080-8082" }
)

# Rules this script created under its previous names. Cleared whenever it
# runs, so re-running after an upgrade leaves one rule per port rather than
# two that both work and disagree about what they are called.
$legacy = @("DOS Bridge dosd (TFTP transport)",
            "DOS Bridge dosd (HTTP + intakes)")
foreach ($n in $legacy) {
    if (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $n
        Write-Host "  removed superseded rule: $n"
    }
}

if ($Remove) {
    foreach ($r in $rules) {
        if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -DisplayName $r.Name
            Write-Host "removed: $($r.Name)"
        }
    }
    exit 0
}

Write-Host "opening inbound for the DOS boxes"
Write-Host "  profiles : $Profile"
Write-Host "  from     : $Subnet"
Write-Host ""

foreach ($r in $rules) {
    if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $r.Name
    }
    New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
        -Protocol $r.Protocol -LocalPort $r.Port -Profile $Profile `
        -RemoteAddress $Subnet -Enabled True | Out-Null
    Write-Host ("  added  {0,-4} {1,-10} {2}" -f $r.Protocol, $r.Port, $r.Name)
}

Write-Host ""
Write-Host "Done. The boxes should start polling within a few seconds:"
Write-Host "    dosstatus"
Write-Host ""
Write-Host "To undo:  dosfirewall.cmd -Remove"
