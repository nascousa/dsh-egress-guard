# Blocks the DeepSeek endpoints DSH can reach, at the OS resolver, for both
# IPv4 and IPv6. This is defense in depth for the DSH profile patch.
#
#   Elevated run to apply:  pwsh -File block-deepseek-hosts.ps1
#   Preview without admin:  pwsh -File block-deepseek-hosts.ps1 -DryRun
#   Self-test without admin: pwsh -File block-deepseek-hosts.ps1 -SelfTest
#   Undo (elevated):        pwsh -File block-deepseek-hosts.ps1 -Remove

[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$hostsPath = if ($env:SystemRoot) {
    Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
} else {
    '/etc/hosts'
}
$beginMarker = '# >>> dsh: block DeepSeek endpoints >>>'
$endMarker = '# <<< dsh: block DeepSeek endpoints <<<'

$targetManifest = Import-PowerShellDataFile -LiteralPath (
    Join-Path $PSScriptRoot 'deepseek-targets.psd1'
)
$targetDefinitions = @(
    $targetManifest.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object {
            [pscustomobject]@{
                Host = [string]$_.Key
                Reason = [string]$_.Value
            }
        }
)
$targets = [ordered]@{}
foreach ($target in $targetDefinitions) {
    $targets[$target.Host] = $target.Reason
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-HostsLines {
    if (-not (Test-Path -LiteralPath $hostsPath)) {
        throw "hosts file not found: $hostsPath"
    }

    return @(Get-Content -LiteralPath $hostsPath)
}

function Remove-ManagedBlock {
    param([string[]]$Lines)

    if ($Lines.Count -eq 0) {
        return @()
    }

    $beginIndexes = @(
        0..($Lines.Count - 1) | Where-Object { $Lines[$_].Trim() -eq $beginMarker }
    )
    $endIndexes = @(
        0..($Lines.Count - 1) | Where-Object { $Lines[$_].Trim() -eq $endMarker }
    )

    if ($beginIndexes.Count -ne $endIndexes.Count -or $beginIndexes.Count -gt 1) {
        throw 'The managed hosts block is malformed or ambiguous. No changes were made.'
    }

    if ($beginIndexes.Count -eq 0) {
        return @($Lines)
    }

    $beginIndex = [int]$beginIndexes[0]
    $endIndex = [int]$endIndexes[0]
    if ($beginIndex -gt $endIndex) {
        throw 'The managed hosts block has its markers in the wrong order. No changes were made.'
    }

    $kept = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($index -lt $beginIndex -or $index -gt $endIndex) {
            $kept.Add($Lines[$index])
        }
    }
    return @($kept)
}

function New-ManagedBlock {
    $block = [System.Collections.Generic.List[string]]::new()
    $block.Add($beginMarker)
    $block.Add('# Managed by block-deepseek-hosts.ps1 - remove with -Remove.')
    foreach ($entry in $targets.GetEnumerator()) {
        $block.Add(('0.0.0.0 {0}    # {1}' -f $entry.Key, $entry.Value))
        $block.Add(('::1     {0}    # IPv6 sinkhole: {1}' -f $entry.Key, $entry.Value))
    }
    $block.Add($endMarker)
    return $block
}

function Write-HostsLines {
    param([System.Collections.Generic.List[string]]$Lines)

    while ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1].Trim() -eq '') {
        $Lines.RemoveAt($Lines.Count - 1)
    }

    $content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($hostsPath, $content, [Text.UTF8Encoding]::new($false))
}

function Resolve-Addresses {
    param(
        [string]$Name,
        [ValidateSet('A', 'AAAA')]
        [string]$Type
    )

    try {
        return @(
            Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop |
                Where-Object { $_.IPAddress } |
                Select-Object -ExpandProperty IPAddress
        )
    } catch {
        return @()
    }
}

if ($SelfTest) {
    $fixture = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '127.0.0.1 localhost',
        '192.0.2.10 container-host.example.test',
        $beginMarker,
        '0.0.0.0 api.deepseek.com',
        $endMarker,
        '198.51.100.20 workstation.example.test',
        '# ThirdPartyHostsSectionEnd'
    )) {
        $fixture.Add($line)
    }

    $pass = $true
    $check = {
        param([string]$Name, [bool]$Ok)
        if ($Ok) {
            "  PASS  $Name"
        } else {
            "  FAIL  $Name"
            $script:pass = $false
        }
    }

    '--- self test ---'
    $stripped = @(Remove-ManagedBlock -Lines $fixture.ToArray())
    & $check 'strip removes both markers' (
        @($stripped | Where-Object { $_ -eq $beginMarker -or $_ -eq $endMarker }).Count -eq 0
    )
    & $check 'strip removes the sinkhole line' (
        @($stripped | Where-Object { $_ -match 'api\.deepseek\.com' }).Count -eq 0
    )
    & $check 'strip keeps foreign lines before and after the block' (
        $stripped[0] -eq '127.0.0.1 localhost' -and
        $stripped[$stripped.Count - 1] -eq '# ThirdPartyHostsSectionEnd'
    )

    $malformedRejected = $false
    try {
        Remove-ManagedBlock -Lines @('before', $beginMarker, '0.0.0.0 api.deepseek.com')
    } catch {
        $malformedRejected = $true
    }
    & $check 'orphan marker is rejected' $malformedRejected

    $block = @(New-ManagedBlock)
    & $check 'managed block includes every IPv4 target' (
        @($block | Where-Object { $_ -match '^0\.0\.0\.0 ' }).Count -eq $targets.Count
    )
    & $check 'managed block includes every IPv6 target' (
        @($block | Where-Object { $_ -match '^::1 ' }).Count -eq $targets.Count
    )

    $rebuilt = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $stripped) { $rebuilt.Add($line) }
    foreach ($line in $block) { $rebuilt.Add($line) }
    $strippedAgain = @(Remove-ManagedBlock -Lines $rebuilt.ToArray())
    & $check 'strip/apply cycle is idempotent' (
        ($strippedAgain -join "`n") -eq ($stripped -join "`n")
    )

    ''
    if ($pass) {
        'self test: all checks passed.'
        exit 0
    }

    'self test: FAILED.'
    exit 1
}

$elevated = Test-Elevated
$existing = @(Read-HostsLines)
$kept = @(Remove-ManagedBlock -Lines $existing)
$hadBlock = $kept.Count -ne $existing.Count

$desired = [System.Collections.Generic.List[string]]::new()
foreach ($line in $kept) {
    $desired.Add($line)
}

if (-not $Remove) {
    if ($desired.Count -gt 0 -and $desired[$desired.Count - 1] -ne '') {
        $desired.Add('')
    }
    foreach ($line in New-ManagedBlock) {
        $desired.Add($line)
    }
}

"hosts file : $hostsPath"
"elevated   : $elevated"
"action     : $(if ($Remove) { 'REMOVE managed block' } else { 'APPLY managed block' })"
"existing managed block present: $hadBlock"
"foreign hosts lines preserved: $($kept.Count)"
"known DeepSeek hosts in manifest: $($targets.Count)"
''

if ($DryRun) {
    '--- managed block that would be present ---'
    if ($Remove) {
        '(none)'
    } else {
        New-ManagedBlock | ForEach-Object { $_ }
    }
    ''
    'dry run: nothing written.'
    exit 0
}

if (-not $elevated) {
    throw 'This script must run elevated: writing to the hosts file requires Administrator. Re-run from an elevated pwsh, or use -DryRun to preview.'
}

Write-HostsLines -Lines $desired
'hosts file written.'

& ipconfig /flushdns | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'The hosts file was written, but flushing the DNS cache failed.'
}
'dns cache flushed.'
''

'--- verification ---'
if ($Remove) {
    $after = @(Read-HostsLines)
    $remaining = @(
        $after | Where-Object { $_.Trim() -eq $beginMarker -or $_.Trim() -eq $endMarker }
    ).Count
    if ($remaining -eq 0) {
        'managed block removed.'
        exit 0
    }

    throw 'The hosts file still contains a managed marker after removal.'
}

$failures = 0
foreach ($domain in $targets.Keys) {
    $ipv4 = @(Resolve-Addresses -Name $domain -Type A)
    $ipv6 = @(Resolve-Addresses -Name $domain -Type AAAA)
    $blocked4 = $ipv4.Count -gt 0 -and @($ipv4 | Where-Object { $_ -eq '0.0.0.0' }).Count -eq $ipv4.Count
    $blocked6 = $ipv6.Count -gt 0 -and @($ipv6 | Where-Object { $_ -eq '::1' -or $_ -eq '::' }).Count -eq $ipv6.Count

    if ($blocked4 -and $blocked6) {
        "  $domain BLOCKED -> IPv4 $($ipv4 -join ', '); IPv6 $($ipv6 -join ', ')"
    } else {
        $failures += 1
        "  $domain NOT BLOCKED -> IPv4 $(if ($ipv4.Count) { $ipv4 -join ', ' } else { '(none)' }); IPv6 $(if ($ipv6.Count) { $ipv6 -join ', ' } else { '(none)' })"
    }
}

''
if ($failures -eq 0) {
    'all targets are sinkholed for IPv4 and IPv6.'
    exit 0
}

"$failures target(s) did not resolve to managed sinkhole addresses."
exit 1
