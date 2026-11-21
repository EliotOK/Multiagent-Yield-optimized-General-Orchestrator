[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$ThreadId = $(if ($env:CODEX_THREAD_ID) { $env:CODEX_THREAD_ID } else { $env:CODEX_SESSION_ID }),
    [string]$ObservedModel = '',
    [string]$ObservedEffort = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$mapPath = Join-Path $ProjectRoot '.codex\mygo-model-map.json'
if (-not (Test-Path -LiteralPath $mapPath -PathType Leaf)) {
    throw "MYGO model map is missing: $mapPath"
}
$map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($map.schema_version -ne 1) { throw 'Unsupported MYGO model-map schema.' }
if ([string]$map.default_primary -ne 'CURRENT') {
    throw 'MYGO requires default_primary=CURRENT. Reinstall or migrate the project workflow.'
}

$model = $ObservedModel.Trim()
$effort = $ObservedEffort.Trim().ToLowerInvariant()
$source = 'explicit_observation'

function Read-SharedTextLines([string]$Path) {
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            while (-not $reader.EndOfStream) { Write-Output $reader.ReadLine() }
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

if ([string]::IsNullOrWhiteSpace($model)) {
    $source = 'session_metadata'
    if ([string]::IsNullOrWhiteSpace($ThreadId) -or
        $ThreadId -notmatch '^[0-9a-fA-F-]{16,64}$') {
        throw 'Current Codex thread ID is unavailable or invalid; primary profile cannot be resolved safely.'
    }
    $sessionsRoot = Join-Path $CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
        throw "Codex sessions directory is unavailable: $sessionsRoot"
    }
    $sessionFiles = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File `
        -Filter "*$ThreadId*.jsonl" -ErrorAction Stop | Sort-Object LastWriteTime)
    if ($sessionFiles.Count -eq 0) {
        throw "No Codex session metadata matches the current thread ID: $ThreadId"
    }

    foreach ($sessionFile in $sessionFiles) {
        foreach ($line in Read-SharedTextLines $sessionFile.FullName) {
            try { $record = $line | ConvertFrom-Json -ErrorAction Stop }
            catch { continue }
            $candidateModel = ''
            $candidateEffort = ''
            if ($null -ne $record.payload.thread_settings) {
                $candidateModel = [string]$record.payload.thread_settings.model
                $candidateEffort = [string]$record.payload.thread_settings.reasoning_effort
            }
            elseif ($record.type -eq 'turn_context') {
                $candidateModel = [string]$record.payload.model
                $candidateEffort = [string]$record.payload.effort
            }
            if (-not [string]::IsNullOrWhiteSpace($candidateModel)) {
                $model = $candidateModel.Trim()
                if (-not [string]::IsNullOrWhiteSpace($candidateEffort)) {
                    $effort = $candidateEffort.Trim().ToLowerInvariant()
                }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw 'Current Codex session metadata contains no readable model identity.'
    }
}

$modelMatches = @()
if ($null -ne $map.primary_profiles) {
    foreach ($profileProperty in $map.primary_profiles.psobject.Properties) {
        $profileName = [string]$profileProperty.Name
        $profile = $profileProperty.Value
        if ($null -eq $profile -or [string]::IsNullOrWhiteSpace([string]$profile.model)) { continue }
        if ([string]$profile.model -ieq $model) {
            $modelMatches += [pscustomobject]@{
                Name = $profileName
                Model = [string]$profile.model
                ExpectedEffort = ([string]$profile.reasoning_effort).ToLowerInvariant()
            }
        }
    }
}

# Known names such as ASTRA and SOL are advisory aliases. Any readable current
# composer model is itself a valid primary; unmapped models use the neutral
# CURRENT profile so model additions do not require a skill release.
if ($modelMatches.Count -eq 0) {
    $resolved = [pscustomobject]@{
        Name = 'CURRENT'
        Model = $model
        ExpectedEffort = ''
    }
}
elseif ($modelMatches.Count -gt 1) {
    $effortMatches = @($modelMatches | Where-Object { $_.ExpectedEffort -eq $effort })
    if ($effortMatches.Count -ne 1) {
        throw "Current model '$model' maps to multiple primary profiles and reasoning effort '$effort' does not disambiguate them."
    }
    $resolved = $effortMatches[0]
}
else { $resolved = $modelMatches[0] }

$effortMatch = if ([string]::IsNullOrWhiteSpace($resolved.ExpectedEffort)) {
    'unknown'
} else {
    ($effort -eq $resolved.ExpectedEffort).ToString().ToLowerInvariant()
}
Write-Output "PRIMARY_PROFILE=$($resolved.Name)"
Write-Output "PRIMARY_MODEL=$model"
Write-Output "PRIMARY_REASONING_EFFORT=$effort"
Write-Output "EXPECTED_REASONING_EFFORT=$($resolved.ExpectedEffort)"
Write-Output "REASONING_EFFORT_MATCH=$effortMatch"
Write-Output "PROFILE_RESOLUTION_SOURCE=$source"
Write-Output 'PRIMARY_PROFILE_RESOLUTION=PASS'
