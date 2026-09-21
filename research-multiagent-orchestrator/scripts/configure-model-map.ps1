[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$MapPath = '',
    [switch]$Apply,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($MapPath)) {
    $MapPath = Join-Path $ProjectRoot '.codex\mygo-model-map.json'
}
$MapPath = [IO.Path]::GetFullPath($MapPath)
if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) {
    throw "MYGO model map is missing: $MapPath"
}

$map = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($map.schema_version -ne 1) { throw 'Unsupported MYGO model-map schema.' }
if ([string]$map.default_primary -ne 'CURRENT') {
    throw 'default_primary must be CURRENT.'
}

$validEfforts = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
$expectedFiles = [ordered]@{
    deepseek_context_worker = 'deepseek-context-worker.toml'
    deepseek_context_reasoning_worker = 'deepseek-context-reasoning-worker.toml'
    deepseek_batch_worker = 'deepseek-batch-worker.toml'
    luna_medium_worker = 'luna-medium-worker.toml'
    luna_high_worker = 'luna-high-worker.toml'
    luna_max_worker = 'luna-max-worker.toml'
    terra_readonly_fallback_worker = 'terra-readonly-fallback-worker.toml'
    terra_fallback_worker = 'terra-fallback-worker.toml'
    astra_review_worker = 'astra-review-worker.toml'
    sol_review_worker = 'sol-review-worker.toml'
}

function Assert-Token([string]$Value, [string]$Field) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9._:/-]+$') {
        throw "Invalid $Field in MYGO model map: $Value"
    }
}

function Set-AgentHeaderValue {
    param([string]$Text, [string]$Key, [string]$Value, [switch]$Remove)
    $marker = 'developer_instructions = """'
    $markerIndex = $Text.IndexOf($marker, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0) { throw 'Agent file has no developer_instructions block.' }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $header = $Text.Substring(0, $markerIndex)
    $tail = $Text.Substring($markerIndex)
    $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"[^"\r\n]*"\s*\r?\n?'
    $matches = @([regex]::Matches($header, $pattern))
    if ($matches.Count -gt 1) { throw "Duplicate agent key: $Key" }
    if ($Remove) {
        $header = [regex]::Replace($header, $pattern, '')
    }
    elseif ($matches.Count -eq 1) {
        $header = [regex]::Replace($header, $pattern, "$Key = `"$Value`"$newline")
    }
    else {
        $descriptionPattern = '(?m)^(description\s*=\s*"[^"\r\n]*"\s*)$'
        if ($header -notmatch $descriptionPattern) { throw 'Agent file has no description field.' }
        $header = [regex]::Replace($header, $descriptionPattern,
            "`$1$newline$Key = `"$Value`"", 1)
    }
    return $header.TrimEnd("`r", "`n") + $newline + $tail
}

foreach ($profileName in @('ASTRA', 'SOL')) {
    $profile = $map.primary_profiles.$profileName
    if ($null -eq $profile) { throw "Missing primary profile: $profileName" }
    Assert-Token ([string]$profile.model) "primary_profiles.$profileName.model"
    if ($profile.reasoning_effort -notin $validEfforts) {
        throw "Invalid primary reasoning effort for $profileName."
    }
}

$properties = @($map.agents.psobject.Properties)
$unknown = @($properties.Name | Where-Object { $_ -notin $expectedFiles.Keys })
$missing = @($expectedFiles.Keys | Where-Object { $_ -notin $properties.Name })
if ($unknown.Count -or $missing.Count) {
    throw "Model-map roles differ from the supported topology. Unknown: $($unknown -join ', '); missing: $($missing -join ', ')."
}
$descriptorPath = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
$deepSeekEnabled = $true
if (Test-Path -LiteralPath $descriptorPath -PathType Leaf) {
    $descriptorText = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8
    if ($descriptorText -match '(?m)^deepseek_enabled\s*=\s*false\s*$') { $deepSeekEnabled = $false }
}

$changes = [System.Collections.Generic.List[object]]::new()
$agentsDir = Join-Path $CodexHome 'agents'
foreach ($role in $expectedFiles.Keys) {
    if (-not $deepSeekEnabled -and $role -like 'deepseek_*') { continue }
    $spec = $map.agents.$role
    if ([string]$spec.file -ne $expectedFiles[$role]) {
        throw "Agent filename is immutable for role ${role}: $($spec.file)"
    }
    if ([string]$spec.codename -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') {
        throw "Invalid codename for ${role}: $($spec.codename)"
    }
    if ($spec.provider -notin @('default', 'deepseek')) {
        throw "Provider for $role must be default or deepseek."
    }
    if (-not $deepSeekEnabled -and $spec.provider -eq 'deepseek') {
        throw "DeepSeek is disabled for this project, but $role is mapped to the deepseek provider."
    }
    Assert-Token ([string]$spec.model) "agents.$role.model"
    if ($spec.reasoning_effort -notin $validEfforts) {
        throw "Invalid reasoning effort for ${role}: $($spec.reasoning_effort)"
    }
    $agentPath = Join-Path $agentsDir $expectedFiles[$role]
    if (-not (Test-Path -LiteralPath $agentPath -PathType Leaf)) {
        throw "Installed agent is missing: $agentPath"
    }
    $oldText = Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8
    $newText = Set-AgentHeaderValue $oldText 'model' ([string]$spec.model)
    $newText = Set-AgentHeaderValue $newText 'model_reasoning_effort' ([string]$spec.reasoning_effort)
    if ($spec.provider -eq 'default') {
        $newText = Set-AgentHeaderValue $newText 'model_provider' '' -Remove
    }
    else {
        $newText = Set-AgentHeaderValue $newText 'model_provider' ([string]$spec.provider)
    }
    if ($newText -cne $oldText) {
        $changes.Add([pscustomobject]@{
            Role = $role; Codename = $spec.codename; Path = $agentPath
            OldText = $oldText; NewText = $newText
        })
    }
}

Write-Output "DEFAULT_PRIMARY=$($map.default_primary)"
Write-Output "PRIMARY_ASTRA=$($map.primary_profiles.ASTRA.model)/$($map.primary_profiles.ASTRA.reasoning_effort)"
Write-Output "PRIMARY_SOL=$($map.primary_profiles.SOL.model)/$($map.primary_profiles.SOL.reasoning_effort)"
foreach ($property in $properties) {
    $spec = $property.Value
    Write-Output "ROLE=$($property.Name) CODENAME=$($spec.codename) PROVIDER=$($spec.provider) MODEL=$($spec.model) EFFORT=$($spec.reasoning_effort)"
}
foreach ($change in $changes) { Write-Output "UPDATE=$($change.Path)" }

if ($Check -and $changes.Count -gt 0) {
    throw "MYGO model map is not applied to $($changes.Count) installed agent file(s)."
}
if ($Apply) {
    $backupRoot = Join-Path $CodexHome 'backups'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }
    foreach ($change in $changes) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $backup = Join-Path $backupRoot ((Split-Path -Leaf $change.Path) + ".model-map-backup-$stamp")
        Copy-Item -LiteralPath $change.Path -Destination $backup
        $temp = $change.Path + '.model-map-tmp'
        $replaceBackup = $null
        try {
            [IO.File]::WriteAllText($temp, $change.NewText, [Text.UTF8Encoding]::new($false))
            $replaceBackup = $temp + '.replace-backup'
            [IO.File]::Replace($temp, $change.Path, $replaceBackup, $true)
            if (Test-Path -LiteralPath $replaceBackup) {
                Remove-Item -LiteralPath $replaceBackup -Force
            }
        }
        finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            if ($replaceBackup -and (Test-Path -LiteralPath $replaceBackup)) {
                Remove-Item -LiteralPath $replaceBackup -Force
            }
        }
    }
    Write-Output 'MODEL_MAP_APPLY=PASS'
    Write-Output 'Fully restart Codex Desktop before using changed agent bindings.'
}
elseif (-not $Check) {
    Write-Output 'MODEL_MAP_PREVIEW=PASS'
    Write-Output 'No files were changed. Rerun with -Apply after reviewing the resolved roles.'
}
