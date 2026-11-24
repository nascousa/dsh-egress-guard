# Verifies the effective DSH profile, not only this bundle's patch text.

[CmdletBinding()]
param(
    [string]$Profile = 'web',
    [string]$DshHome,
    [string]$DshExecutable,
    [string]$DshRepository,
    [string]$DumpFile,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$requiredRows = @(
    'session-log-deepseek',
    'session-telemetry-otel',
    'plugin-package-inventory-deepseek',
    'llm-deepseek',
    'llm-deepseek-account',
    'deepseek-account',
    'web-search-deepseek',
    'plugin-manager',
    'web',
    'dsh-web-search-plugin',
    'agent-default-model'
)
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

function Get-RowBlocks {
    param([string]$Text)

    $matches = [regex]::Matches(
        $Text,
        '(?ms)^- id:\s*(?<id>[^\r\n]+)\r?\n(?<body>.*?)(?=^- id:\s*|\z)'
    )
    $rows = @{}
    foreach ($match in $matches) {
        $id = $match.Groups['id'].Value.Trim().Trim("'`"")
        if (-not $rows.ContainsKey($id)) {
            $rows[$id] = [System.Collections.Generic.List[string]]::new()
        }
        $rows[$id].Add($match.Value)
    }
    return $rows
}

function Test-RowLine {
    param(
        [hashtable]$Rows,
        [string]$Id,
        [string]$Pattern
    )

    if (-not $Rows.ContainsKey($Id) -or $Rows[$Id].Count -ne 1) {
        return $false
    }

    return $Rows[$Id][0] -match $Pattern
}

function Add-Result {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [ValidateSet('PASS', 'FAIL', 'WARN')]
        [string]$Status,
        [string]$Message
    )

    $Results.Add([pscustomobject]@{
        Status = $Status
        Message = $Message
    })
}

function Add-HostsVerification {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [array]$Targets
    )

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $beginMarker = '# >>> dsh: block DeepSeek endpoints >>>'
    $endMarker = '# <<< dsh: block DeepSeek endpoints <<<'
    if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
        Add-Result -Results $Results -Status FAIL -Message "hosts file not found: $hostsPath"
        return
    }

    $lines = @(Get-Content -LiteralPath $hostsPath)
    $beginIndexes = @(
        0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -eq $beginMarker }
    )
    $endIndexes = @(
        0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -eq $endMarker }
    )
    if (
        $beginIndexes.Count -ne 1 -or
        $endIndexes.Count -ne 1 -or
        $beginIndexes[0] -ge $endIndexes[0]
    ) {
        Add-Result -Results $Results -Status FAIL -Message 'hosts file does not contain exactly one well-formed guard block'
        return
    }

    $block = @($lines[$beginIndexes[0]..$endIndexes[0]])
    $missingRules = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $Targets) {
        $escapedHost = [regex]::Escape($target.Host)
        $ipv4Count = @(
            $block | Where-Object {
                $_ -match ('^\s*0\.0\.0\.0\s+' + $escapedHost + '(?:\s|$)')
            }
        ).Count
        $ipv6Count = @(
            $block | Where-Object {
                $_ -match ('^\s*::1\s+' + $escapedHost + '(?:\s|$)')
            }
        ).Count
        if ($ipv4Count -ne 1 -or $ipv6Count -ne 1) {
            $missingRules.Add($target.Host)
        }
    }

    if ($missingRules.Count -eq 0) {
        Add-Result -Results $Results -Status PASS -Message "hosts block covers all $($Targets.Count) known DeepSeek hosts for IPv4 and IPv6"
    } else {
        Add-Result -Results $Results -Status FAIL -Message "hosts block is missing or duplicates rules for: $($missingRules -join ', ')"
    }

    $dnsFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $Targets) {
        try {
            $ipv4 = @(
                Resolve-DnsName -Name $target.Host -Type A -ErrorAction Stop |
                    Where-Object { $_.IPAddress } |
                    Select-Object -ExpandProperty IPAddress
            )
            $ipv6 = @(
                Resolve-DnsName -Name $target.Host -Type AAAA -ErrorAction Stop |
                    Where-Object { $_.IPAddress } |
                    Select-Object -ExpandProperty IPAddress
            )
        } catch {
            $dnsFailures.Add("$($target.Host) (DNS lookup failed)")
            continue
        }

        $blocked4 = $ipv4.Count -gt 0 -and
            @($ipv4 | Where-Object { $_ -eq '0.0.0.0' }).Count -eq $ipv4.Count
        $blocked6 = $ipv6.Count -gt 0 -and
            @($ipv6 | Where-Object { $_ -eq '::1' }).Count -eq $ipv6.Count
        if (-not $blocked4 -or -not $blocked6) {
            $dnsFailures.Add(
                "$($target.Host) (A=$($ipv4 -join ','); AAAA=$($ipv6 -join ','))"
            )
        }
    }

    if ($dnsFailures.Count -eq 0) {
        Add-Result -Results $Results -Status PASS -Message 'DNS resolves all known DeepSeek hosts to local sinkholes'
    } else {
        Add-Result -Results $Results -Status FAIL -Message "DNS sinkhole verification failed for: $($dnsFailures -join '; ')"
    }
}

function Get-DumpText {
    if ($DumpFile) {
        if (-not (Test-Path -LiteralPath $DumpFile -PathType Leaf)) {
            throw "Dump file not found: $DumpFile"
        }
        return Get-Content -LiteralPath $DumpFile -Raw
    }

    if ($DshRepository) {
        $cli = Join-Path $DshRepository 'apps\cli\src\bin.ts'
        if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
            throw "DSH CLI not found: $cli"
        }
        Push-Location $DshRepository
        try {
            if ($Profile -ieq 'desktop') {
                $profileJson = ConvertTo-Json $Profile -Compress
                $expression = @"
const { runDumpConfig } = await import('./apps/cli/src/dump-config.ts');
runDumpConfig($profileJson, false, []);
"@
                $output = @(
                    & node --import tsx/esm --input-type=module --eval $expression 2>&1
                )
            } else {
                $output = @(& node --import tsx/esm $cli --profile $Profile --dump-config 2>&1)
            }
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($exitCode -ne 0) {
            throw "DSH dump-config failed: $($output -join ' ')"
        }
        return $output -join "`n"
    }

    $command = $DshExecutable
    if (-not $command) {
        $knownCommand = Get-Command dsh -ErrorAction SilentlyContinue
        if ($knownCommand) {
            $command = $knownCommand.Source
        }
    }
    if (-not $command) {
        $autoRepository = Join-Path $env:USERPROFILE 'deepseek-harness'
        if (Test-Path -LiteralPath (Join-Path $autoRepository 'apps\cli\src\bin.ts') -PathType Leaf) {
            return Get-DumpText -DshRepository $autoRepository
        }
        throw 'DSH was not found. Pass -DshExecutable, -DshRepository, or -DumpFile.'
    }

    $output = @(& $command --profile $Profile --dump-config 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "DSH dump-config failed: $($output -join ' ')"
    }
    return $output -join "`n"
}

if ($SelfTest) {
    $fixture = @'
- id: session-log-deepseek
  config:
    enabled: false
- id: dsh-web-search-plugin
  config:
    provider: exa
- id: agent-default-model
  config:
    provider: deepinfra
'@
    $rows = Get-RowBlocks -Text $fixture
    if (
        $rows.Count -eq 3 -and
        (Test-RowLine -Rows $rows -Id 'session-log-deepseek' -Pattern '(?m)^\s+enabled:\s*false\s*$') -and
        (Test-RowLine -Rows $rows -Id 'dsh-web-search-plugin' -Pattern '(?m)^\s+provider:\s*exa\s*$')
    ) {
        'self test: all checks passed.'
        exit 0
    }

    'self test: FAILED.'
    exit 1
}

if (-not $DshHome) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
}

$results = [System.Collections.Generic.List[object]]::new()
$text = Get-DumpText
$rows = Get-RowBlocks -Text $text

foreach ($id in $requiredRows) {
    $count = if ($rows.ContainsKey($id)) { $rows[$id].Count } else { 0 }
    if ($count -eq 1) {
        Add-Result -Results $results -Status PASS -Message "$id occurs exactly once"
    } else {
        Add-Result -Results $results -Status FAIL -Message "$id must occur exactly once; found $count"
    }
}

$checks = @(
    @{ Id = 'session-log-deepseek'; Pattern = '(?m)^\s+enabled:\s*false\s*$'; Message = 'session upload is disabled' },
    @{ Id = 'session-telemetry-otel'; Pattern = '(?m)^\s+mode:\s*DISABLED\s*$'; Message = 'OTLP telemetry is disabled' },
    @{ Id = 'plugin-package-inventory-deepseek'; Pattern = '(?m)^\s+disabled:\s*true\s*$'; Message = 'package inventory upload row is disabled' },
    @{ Id = 'llm-deepseek'; Pattern = '(?m)^\s+disabled:\s*true\s*$'; Message = 'DeepSeek API-key LLM route is disabled' },
    @{ Id = 'llm-deepseek-account'; Pattern = '(?m)^\s+disabled:\s*true\s*$'; Message = 'DeepSeek account LLM route is disabled' },
    @{ Id = 'deepseek-account'; Pattern = '(?m)^\s+disabled:\s*true\s*$'; Message = 'DeepSeek account platform is disabled' },
    @{ Id = 'web-search-deepseek'; Pattern = '(?m)^\s+disabled:\s*true\s*$'; Message = 'native DeepSeek search route is disabled' },
    @{ Id = 'plugin-manager'; Pattern = '(?m)^\s+fallbackRegistries:\s*\[\]\s*$'; Message = 'DeepSeek-adjacent registry fallback is removed' },
    @{ Id = 'web'; Pattern = '(?m)^\s+searchProvider:\s*dsh-web-search\s*$'; Message = 'web search uses the replacement provider' },
    @{ Id = 'agent-default-model'; Pattern = '(?m)^\s+provider:\s*(?!deepseek-official\b).+\s*$'; Message = 'default model no longer selects DeepSeek directly' }
)

foreach ($check in $checks) {
    if (Test-RowLine -Rows $rows -Id $check.Id -Pattern $check.Pattern) {
        Add-Result -Results $results -Status PASS -Message $check.Message
    } else {
        Add-Result -Results $results -Status FAIL -Message $check.Message
    }
}

$allowedSearchProviders = @('tavily', 'searxng', 'exa', 'brave', 'serper', 'serpapi', 'scavio', 'firecrawl')
$searchSafe = $false
if ($rows.ContainsKey('dsh-web-search-plugin') -and $rows['dsh-web-search-plugin'].Count -eq 1) {
    foreach ($provider in $allowedSearchProviders) {
        if ($rows['dsh-web-search-plugin'][0] -match ('(?m)^\s+provider:\s*' + [regex]::Escape($provider) + '\s*$')) {
            $searchSafe = $true
            break
        }
    }
}
if ($searchSafe) {
    Add-Result -Results $results -Status PASS -Message 'replacement search provider is non-DeepSeek'
} else {
    Add-Result -Results $results -Status FAIL -Message 'replacement search provider is missing, duplicated, unknown, or DeepSeek-backed'
}

if ($text -match '(?m)^\s+provider:\s*deepseek-official\s*$') {
    Add-Result -Results $results -Status FAIL -Message 'effective config still contains provider: deepseek-official'
} else {
    Add-Result -Results $results -Status PASS -Message 'effective config contains no deepseek-official provider'
}

$profileRoot = Join-Path $DshHome "profiles\$Profile"
$guardPackagePath = Join-Path $profileRoot 'node_modules\dsh-egress-guard\package.json'
$searchPackagePath = Join-Path $profileRoot 'node_modules\dsh-web-search-plugin\package.json'
$expectedGuard = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\package.json') -Raw | ConvertFrom-Json

if (Test-Path -LiteralPath $guardPackagePath -PathType Leaf) {
    $installedGuard = Get-Content -LiteralPath $guardPackagePath -Raw | ConvertFrom-Json
    if ($installedGuard.version -eq $expectedGuard.version) {
        Add-Result -Results $results -Status PASS -Message "installed guard version is $($expectedGuard.version)"
    } else {
        Add-Result -Results $results -Status FAIL -Message "installed guard is $($installedGuard.version); expected $($expectedGuard.version)"
    }
} else {
    Add-Result -Results $results -Status FAIL -Message "guard package is not installed at $guardPackagePath"
}

if (Test-Path -LiteralPath $searchPackagePath -PathType Leaf) {
    $installedSearch = Get-Content -LiteralPath $searchPackagePath -Raw | ConvertFrom-Json
    if ($installedSearch.version -eq '0.5.1') {
        Add-Result -Results $results -Status PASS -Message 'audited search plugin version is 0.5.1'
    } else {
        Add-Result -Results $results -Status FAIL -Message "installed search plugin is $($installedSearch.version); expected audited version 0.5.1"
    }
} else {
    Add-Result -Results $results -Status FAIL -Message 'dsh-web-search-plugin is not installed'
}

$profilePackagePath = Join-Path $profileRoot 'package.json'
if (Test-Path -LiteralPath $profilePackagePath -PathType Leaf) {
    $profilePackage = Get-Content -LiteralPath $profilePackagePath -Raw | ConvertFrom-Json
    if ($profilePackage.dependencies.PSObject.Properties.Name -contains 'dsh-web-search-plugin') {
        Add-Result -Results $results -Status WARN -Message 'profile directly declares dsh-web-search-plugin; rely on the guard dependency unless a separate install is intentional'
    } else {
        Add-Result -Results $results -Status PASS -Message 'search plugin is supplied only by the guard dependency'
    }
}

Add-HostsVerification -Results $results -Targets $targetDefinitions

foreach ($result in $results) {
    '{0,-4}  {1}' -f $result.Status, $result.Message
}

$failures = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
''
if ($failures -eq 0) {
    'profile verification: PASS'
    exit 0
}

"profile verification: FAIL ($failures failure(s))"
exit 1
