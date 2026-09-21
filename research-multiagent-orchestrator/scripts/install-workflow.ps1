[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [switch]$Apply,
    [switch]$ForceAgentUpdate,
    [switch]$LunaOnly,
    [switch]$ProjectOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$SkillRoot = Split-Path -Parent $PSScriptRoot
$AssetRoot = Join-Path $SkillRoot 'assets'
$Actions = [System.Collections.Generic.List[string]]::new()
$TransactionFiles = [System.Collections.Generic.List[object]]::new()
$TransactionDirectories = [System.Collections.Generic.List[string]]::new()
$TransactionCommitted = $false
$installMutex = $null
$installMutexAcquired = $false

trap {
    if ($Apply -and -not $TransactionCommitted -and
        ($TransactionFiles.Count -gt 0 -or $TransactionDirectories.Count -gt 0)) {
        for ($i = $TransactionFiles.Count - 1; $i -ge 0; $i--) {
            $record = $TransactionFiles[$i]
            try {
                if ($record.Existed) {
                    Copy-Item -LiteralPath $record.Backup -Destination $record.Path -Force
                }
                elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) {
                    Remove-Item -LiteralPath $record.Path -Force
                }
            }
            catch { Write-Warning "Rollback could not restore $($record.Path): $($_.Exception.Message)" }
        }
        for ($i = $TransactionDirectories.Count - 1; $i -ge 0; $i--) {
            try {
                $dir = $TransactionDirectories[$i]
                if ((Test-Path -LiteralPath $dir -PathType Container) -and
                    @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $dir -Force
                }
            }
            catch { Write-Warning "Rollback could not remove ${dir}: $($_.Exception.Message)" }
        }
        Write-Warning 'Installation failed; attempted to roll back every change from this run.'
    }
    if ($installMutexAcquired) { $installMutex.ReleaseMutex(); $script:installMutexAcquired = $false }
    if ($null -ne $installMutex) { $installMutex.Dispose(); $script:installMutex = $null }
    throw $_
}

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $ProjectRoot"
}
if ($ProjectRoot.Equals($CodexHome, [StringComparison]::OrdinalIgnoreCase) -or
    $ProjectRoot.StartsWith($CodexHome + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $CodexHome.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ProjectRoot and CodexHome must be separate, non-nested directories.'
}
$installMutex = [Threading.Mutex]::new($false, 'Local\MYGO_INSTALL_GLOBAL')
$installMutexAcquired = $installMutex.WaitOne(0)
if (-not $installMutexAcquired) { throw 'Another MYGO installation is already active for these roots.' }

$environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
$deepSeekKeyPresent = (Test-Path -LiteralPath 'Env:DEEPSEEK_API_KEY') -or
    ($null -ne $environmentKey -and 'DEEPSEEK_API_KEY' -in $environmentKey.GetValueNames())
if ($null -ne $environmentKey) { $environmentKey.Dispose() }
if (-not $LunaOnly -and -not $deepSeekKeyPresent -and $Apply) {
    throw 'DEEPSEEK_API_KEY is missing. No files were changed. Run scripts\set-deepseek-key.ps1 in an interactive terminal, fully restart Codex, then retry; or explicitly use -LunaOnly.'
}

function Add-Action([string]$Message) {
    $script:Actions.Add($Message)
}

function Assert-ManagedPathSafe([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = if ($full.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $ProjectRoot
    }
    elseif ($full.Equals($CodexHome, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($CodexHome + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $CodexHome
    }
    else {
        throw "Managed path is outside the approved roots: $full"
    }

    if (Test-Path -LiteralPath $base) {
        $baseItem = Get-Item -LiteralPath $base -Force
        if (($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use a reparse point as a managed root: $base"
        }
    }
    $cursor = $full
    while (-not $cursor.Equals($base, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to write through a reparse point: $cursor"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
            throw "Could not validate managed path ancestry: $full"
        }
        $cursor = $parent.TrimEnd('\')
    }
}

function Ensure-Directory([string]$Path) {
    Assert-ManagedPathSafe $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Add-Action "CREATE DIR  $Path"
        if ($Apply) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            $script:TransactionDirectories.Add([IO.Path]::GetFullPath($Path).TrimEnd('\'))
        }
    }
}

function Backup-File([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (@($script:TransactionFiles | Where-Object Path -eq $resolved).Count -gt 0) { return }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $resolved = [IO.Path]::GetFullPath($Path)
        $projectPrefix = $ProjectRoot + '\'
        $backupRoot = if ($resolved.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Join-Path $ProjectRoot '.codex\diagnostics\backups'
        }
        else {
            Join-Path $CodexHome 'backups'
        }
        Ensure-Directory $backupRoot
        $backup = Join-Path $backupRoot ((Split-Path -Leaf $Path) + ".rmo-backup-$stamp")
        Assert-ManagedPathSafe $backup
        Copy-Item -LiteralPath $Path -Destination $backup
        $script:TransactionFiles.Add([pscustomobject]@{
            Path = $resolved; Existed = $true; Backup = $backup
        })
        Add-Action "BACKUP      $backup"
    }
    else {
        $script:TransactionFiles.Add([pscustomobject]@{
            Path = $resolved; Existed = $false; Backup = $null
        })
    }
}

function Write-AtomicText([string]$Path, [string]$Text) {
    Assert-ManagedPathSafe $Path
    Backup-File $Path
    $directory = Split-Path -Parent $Path
    $temp = Join-Path $directory ('.rmo-write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $replaceBackup = $temp + '.replace-backup'
            [IO.File]::Replace($temp, $Path, $replaceBackup, $true)
            if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force }
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Set-TomlSetting {
    param([string]$Text, [string]$Section, [string]$Key, [string]$Value)

    $lines = @($Text -split '\r?\n')
    $headers = @()
    $inBasicMultiline = $false
    $inLiteralMultiline = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $inLiteralMultiline -and ([regex]::Matches($line, '"""').Count % 2 -eq 1)) {
            $inBasicMultiline = -not $inBasicMultiline
        }
        if (-not $inBasicMultiline -and ([regex]::Matches($line, "'''").Count % 2 -eq 1)) {
            $inLiteralMultiline = -not $inLiteralMultiline
        }
        if (-not $inBasicMultiline -and -not $inLiteralMultiline -and
            $line -match '^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$') {
            $headers += [pscustomobject]@{ Name = $Matches[1]; Index = $i }
        }
    }
    if ($inBasicMultiline -or $inLiteralMultiline) { throw 'Unterminated multiline TOML string.' }
    $matches = @($headers | Where-Object Name -eq $Section)
    if ($matches.Count -gt 1) { throw "Duplicate TOML section is ambiguous: [$Section]" }
    if ($matches.Count -eq 0) {
        $separator = if ([string]::IsNullOrWhiteSpace($Text)) { '' } else { "`r`n`r`n" }
        return $Text.TrimEnd() + $separator + "[$Section]`r`n$Key = $Value`r`n"
    }

    $start = $matches[0].Index
    $nextHeader = @($headers | Where-Object Index -gt $start | Sort-Object Index | Select-Object -First 1)
    $end = if ($nextHeader.Count -eq 1) { $nextHeader[0].Index - 1 } else { $lines.Count - 1 }
    $keyMatches = @()
    $inBasicMultiline = $false
    $inLiteralMultiline = $false
    for ($i = $start + 1; $i -le $end; $i++) {
        $line = $lines[$i]
        $wasInMultiline = $inBasicMultiline -or $inLiteralMultiline
        if (-not $inLiteralMultiline -and ([regex]::Matches($line, '"""').Count % 2 -eq 1)) {
            $inBasicMultiline = -not $inBasicMultiline
        }
        if (-not $inBasicMultiline -and ([regex]::Matches($line, "'''").Count % 2 -eq 1)) {
            $inLiteralMultiline = -not $inLiteralMultiline
        }
        if (-not $wasInMultiline -and -not $inBasicMultiline -and -not $inLiteralMultiline -and
            $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) { $keyMatches += $i }
    }
    if ($keyMatches.Count -gt 1) { throw "Duplicate TOML key is ambiguous: [$Section].$Key" }
    if ($keyMatches.Count -eq 1) {
        $lines[$keyMatches[0]] = "$Key = $Value"
    }
    else {
        $before = if ($end -ge 0) { @($lines[0..$end]) } else { @() }
        $after = if ($end + 1 -lt $lines.Count) { @($lines[($end + 1)..($lines.Count - 1)]) } else { @() }
        $lines = @($before + "$Key = $Value" + $after)
    }
    return ($lines -join "`r`n").TrimEnd() + "`r`n"
}

function Normalize-Newlines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ([regex]::Replace($Text, "\r\n|\r|\n", "`r`n")).TrimEnd() + "`r`n"
}

function Normalize-AgentTemplate([string]$Text) {
    $normalized = Normalize-Newlines $Text
    return ([regex]::Replace($normalized,
        '(?m)^(model_provider|model|model_reasoning_effort)\s*=\s*"[^"\r\n]*"\s*\r?\n?',
        '')).TrimEnd() + "`r`n"
}

function Set-ManagedBlock {
    param(
        [string]$Path,
        [string]$Block,
        [string]$StartMarker,
        [string]$EndMarker
    )

    Assert-ManagedPathSafe $Path
    $old = if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } else { '' }
    $oldNormalized = Normalize-Newlines $old
    $blockNormalized = Normalize-Newlines $Block
    $startMatches = @([regex]::Matches($oldNormalized, '(?m)^[ \t]*' + [regex]::Escape($StartMarker) + '[ \t]*\r?$'))
    $endMatches = @([regex]::Matches($oldNormalized, '(?m)^[ \t]*' + [regex]::Escape($EndMarker) + '[ \t]*\r?$'))
    if ($startMatches.Count -eq 1 -and $endMatches.Count -eq 1 -and
        $startMatches[0].Index -lt $endMatches[0].Index) {
        $endOffset = $endMatches[0].Index + $endMatches[0].Length
        $new = $oldNormalized.Substring(0, $startMatches[0].Index) + $blockNormalized.TrimEnd() +
            $oldNormalized.Substring($endOffset)
    }
    elseif ($startMatches.Count -ne 0 -or $endMatches.Count -ne 0) {
        throw "Managed block markers are incomplete, duplicated, or out of order: $Path"
    }
    else {
        $prefix = if ([string]::IsNullOrWhiteSpace($oldNormalized)) { '' } else { $oldNormalized.TrimEnd() + "`r`n`r`n" }
        $new = $prefix + $blockNormalized.TrimEnd() + "`r`n"
    }
    $new = Normalize-Newlines $new
    if ($new -cne $oldNormalized) {
        Add-Action "UPDATE      $Path"
        if ($Apply) {
            Write-AtomicText $Path $new
        }
    }
}

function Assert-ManagedBlockUnambiguous {
    param([string]$Path, [string]$StartMarker, [string]$EndMarker)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $starts = @([regex]::Matches($text, '(?m)^[ \t]*' + [regex]::Escape($StartMarker) + '[ \t]*\r?$'))
    $ends = @([regex]::Matches($text, '(?m)^[ \t]*' + [regex]::Escape($EndMarker) + '[ \t]*\r?$'))
    if (($starts.Count -eq 0 -and $ends.Count -eq 0)) { return }
    if ($starts.Count -ne 1 -or $ends.Count -ne 1 -or $starts[0].Index -ge $ends[0].Index) {
        throw "Managed block markers are incomplete, duplicated, or out of order: $Path"
    }
}

# Perform every predictable conflict and path-safety check before the first write.
$projectManagedPaths = @(
    (Join-Path $ProjectRoot '.codex'),
    (Join-Path $ProjectRoot '.codex\tasks'),
    (Join-Path $ProjectRoot '.codex\bindings'),
    (Join-Path $ProjectRoot '.codex\diagnostics'),
    (Join-Path $ProjectRoot 'work'),
    (Join-Path $ProjectRoot 'work\worker_state'),
    (Join-Path $ProjectRoot '.codex\research-multiagent.toml'),
    (Join-Path $ProjectRoot '.codex\mygo-model-map.json'),
    (Join-Path $ProjectRoot 'AGENTS.md'),
    (Join-Path $ProjectRoot '.gitignore')
)
$projectManagedPaths | ForEach-Object { Assert-ManagedPathSafe $_ }
Assert-ManagedBlockUnambiguous -Path (Join-Path $ProjectRoot 'AGENTS.md') `
    -StartMarker '<!-- research-multiagent-orchestrator:start -->' `
    -EndMarker '<!-- research-multiagent-orchestrator:end -->'
Assert-ManagedBlockUnambiguous -Path (Join-Path $ProjectRoot '.gitignore') `
    -StartMarker '# research-multiagent-orchestrator:start' `
    -EndMarker '# research-multiagent-orchestrator:end'
$preflightModelMapPath = Join-Path $ProjectRoot '.codex\mygo-model-map.json'
if (Test-Path -LiteralPath $preflightModelMapPath -PathType Leaf) {
    try {
        $preflightModelMap = Get-Content -LiteralPath $preflightModelMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($preflightModelMap.schema_version -ne 1) { throw 'unsupported schema' }
    }
    catch {
        throw "Existing MYGO model map is invalid; no files were changed: $preflightModelMapPath"
    }
}

if (-not $ProjectOnly) {
    foreach ($path in @($CodexHome, (Join-Path $CodexHome 'agents'),
            (Join-Path $CodexHome 'config.toml'), (Join-Path $CodexHome 'AGENTS.md'))) {
        Assert-ManagedPathSafe $path
    }
    $preflightAgentSource = Join-Path $AssetRoot 'agents'
    foreach ($source in Get-ChildItem -LiteralPath $preflightAgentSource -Filter '*.toml' -File) {
        if ($LunaOnly -and $source.Name -like 'deepseek-*') { continue }
        $target = Join-Path (Join-Path $CodexHome 'agents') $source.Name
        Assert-ManagedPathSafe $target
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and -not $ForceAgentUpdate) {
            $sourceText = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
            $targetText = Get-Content -LiteralPath $target -Raw -Encoding UTF8
            if ($sourceText -cne $targetText -and
                (Normalize-AgentTemplate $sourceText) -cne (Normalize-AgentTemplate $targetText) -and
                $Apply) {
                throw "Refusing to overwrite custom agent before making any changes: $target"
            }
        }
    }
    $preflightGlobal = Join-Path $CodexHome 'AGENTS.md'
    Assert-ManagedBlockUnambiguous -Path $preflightGlobal `
        -StartMarker '<!-- research-multiagent-orchestrator-global:start -->' `
        -EndMarker '<!-- research-multiagent-orchestrator-global:end -->'
    if (Test-Path -LiteralPath $preflightGlobal -PathType Leaf) {
        $preflightGlobalText = Get-Content -LiteralPath $preflightGlobal -Raw -Encoding UTF8
        $preflightLegacy = ($preflightGlobalText -match 'Use the `deepseek_worker` custom subagent') -or
            ($preflightGlobalText -match 'Write the complete bounded assignment to `\.codex/deepseek-worker-task\.md`')
        if ($preflightLegacy -and $Apply) {
            throw 'Legacy global routing requires manual migration. No files were changed.'
        }
    }
    $preflightConfigPath = Join-Path $CodexHome 'config.toml'
    if (Test-Path -LiteralPath $preflightConfigPath -PathType Leaf) {
        $preflightConfigText = Get-Content -LiteralPath $preflightConfigPath -Raw -Encoding UTF8
        $preflightConfigText = Set-TomlSetting $preflightConfigText 'agents' 'enabled' 'true'
        $preflightConfigText = Set-TomlSetting $preflightConfigText 'agents' 'max_concurrent_threads_per_session' '1'
        if (-not $LunaOnly) {
            foreach ($setting in @(
                @('name', '"DeepSeek"'), @('base_url', '"https://api.deepseek.com/"'),
                @('wire_api', '"responses"'), @('env_key', '"DEEPSEEK_API_KEY"'),
                @('supports_websockets', 'false'))) {
                $preflightConfigText = Set-TomlSetting $preflightConfigText `
                    'model_providers.deepseek' $setting[0] $setting[1]
            }
        }
    }
}
else {
    $requiredAgentNames = @('luna-medium-worker.toml', 'luna-high-worker.toml',
        'luna-max-worker.toml', 'terra-readonly-fallback-worker.toml',
        'terra-fallback-worker.toml', 'astra-review-worker.toml',
        'sol-review-worker.toml')
    if (-not $LunaOnly) {
        $requiredAgentNames = @('deepseek-context-worker.toml',
            'deepseek-context-reasoning-worker.toml', 'deepseek-batch-worker.toml') +
            $requiredAgentNames
    }
    $projectOnlyConfig = Join-Path $CodexHome 'config.toml'
    $missingPrerequisites = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $projectOnlyConfig -PathType Leaf)) {
        $missingPrerequisites.Add($projectOnlyConfig)
    }
    else {
        $projectOnlyConfigText = Get-Content -LiteralPath $projectOnlyConfig -Raw -Encoding UTF8
        try {
            $projectOnlyConfigProbe = Set-TomlSetting $projectOnlyConfigText 'agents' 'enabled' 'true'
            $projectOnlyConfigProbe = Set-TomlSetting $projectOnlyConfigProbe 'agents' 'max_concurrent_threads_per_session' '1'
        }
        catch {
            throw "Project-only config prerequisite is ambiguous; no files were changed: $($_.Exception.Message)"
        }
        if ($projectOnlyConfigProbe -cne (Normalize-Newlines $projectOnlyConfigText)) {
            $missingPrerequisites.Add('config.toml: agents.enabled=true')
        }
        if (-not $LunaOnly) {
            foreach ($setting in @(
                @('name', '"DeepSeek"'), @('base_url', '"https://api.deepseek.com/"'),
                @('wire_api', '"responses"'), @('env_key', '"DEEPSEEK_API_KEY"'),
                @('supports_websockets', 'false'))) {
                $providerProbe = Set-TomlSetting $projectOnlyConfigProbe `
                    'model_providers.deepseek' $setting[0] $setting[1]
                if ($providerProbe -cne $projectOnlyConfigProbe) {
                    $missingPrerequisites.Add("config.toml: DeepSeek provider $($setting[0])")
                }
                $projectOnlyConfigProbe = $providerProbe
            }
        }
    }
    foreach ($name in $requiredAgentNames) {
        $agentPath = Join-Path (Join-Path $CodexHome 'agents') $name
        if (-not (Test-Path -LiteralPath $agentPath -PathType Leaf)) {
            $missingPrerequisites.Add($agentPath)
        }
        else {
            $expectedAgentPath = Join-Path (Join-Path $AssetRoot 'agents') $name
            $installedAgentText = Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8
            $expectedAgentText = Get-Content -LiteralPath $expectedAgentPath -Raw -Encoding UTF8
            if ((Normalize-AgentTemplate $installedAgentText) -cne (Normalize-AgentTemplate $expectedAgentText)) {
                $missingPrerequisites.Add("incompatible agent: $agentPath")
            }
        }
    }
    if ($missingPrerequisites.Count -gt 0) {
        throw "Project-only prerequisites are missing; no files were changed: $($missingPrerequisites -join '; ')"
    }
}

if (-not $ProjectOnly) {
Ensure-Directory $CodexHome
Ensure-Directory (Join-Path $CodexHome 'agents')

$configPath = Join-Path $CodexHome 'config.toml'
$oldConfig = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
} else { '' }
$newConfig = $oldConfig
$newConfig = Set-TomlSetting $newConfig 'agents' 'enabled' 'true'
$newConfig = Set-TomlSetting $newConfig 'agents' 'max_concurrent_threads_per_session' '1'
if (-not $LunaOnly) {
    $newConfig = Set-TomlSetting $newConfig 'model_providers.deepseek' 'name' '"DeepSeek"'
    $newConfig = Set-TomlSetting $newConfig 'model_providers.deepseek' 'base_url' '"https://api.deepseek.com/"'
    $newConfig = Set-TomlSetting $newConfig 'model_providers.deepseek' 'wire_api' '"responses"'
    $newConfig = Set-TomlSetting $newConfig 'model_providers.deepseek' 'env_key' '"DEEPSEEK_API_KEY"'
    $newConfig = Set-TomlSetting $newConfig 'model_providers.deepseek' 'supports_websockets' 'false'
}
$newConfig = Normalize-Newlines $newConfig
$oldConfigNormalized = Normalize-Newlines $oldConfig
if ($newConfig -cne $oldConfigNormalized) {
    Add-Action "UPDATE      $configPath"
    if ($Apply) {
        Write-AtomicText $configPath $newConfig
    }
}

$agentSource = Join-Path $AssetRoot 'agents'
foreach ($source in Get-ChildItem -LiteralPath $agentSource -Filter '*.toml' -File) {
    if ($LunaOnly -and $source.Name -like 'deepseek-*') { continue }
    $target = Join-Path (Join-Path $CodexHome 'agents') $source.Name
    $sourceText = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
    $targetText = if (Test-Path -LiteralPath $target) {
        Get-Content -LiteralPath $target -Raw -Encoding UTF8
    } else { $null }
    if ($sourceText -cne $targetText) {
        if ($null -ne $targetText -and
            (Normalize-AgentTemplate $sourceText) -ceq (Normalize-AgentTemplate $targetText)) {
            Add-Action "PRESERVE    $target (model map binding)"
        }
        elseif ($null -ne $targetText -and -not $ForceAgentUpdate) {
            Add-Action "CONFLICT    $target (rerun with -ForceAgentUpdate after review)"
            if ($Apply) { throw "Refusing to overwrite custom agent: $target" }
        }
        else {
            Add-Action "INSTALL     $target"
            if ($Apply) {
                Write-AtomicText $target $sourceText
            }
        }
    }
}

$globalAgentsPath = Join-Path $CodexHome 'AGENTS.md'
$globalAsset = if ($LunaOnly) { 'global\AGENTS.luna-only.md' } else { 'global\AGENTS.md' }
$globalBlock = Get-Content -LiteralPath (Join-Path $AssetRoot $globalAsset) -Raw -Encoding UTF8
$oldGlobal = if (Test-Path -LiteralPath $globalAgentsPath) {
    Get-Content -LiteralPath $globalAgentsPath -Raw -Encoding UTF8
} else { '' }
$legacyPositive = ($oldGlobal -match 'Use the `deepseek_worker` custom subagent') -or
    ($oldGlobal -match 'Write the complete bounded assignment to `\.codex/deepseek-worker-task\.md`')
if ($legacyPositive) {
    Add-Action "CONFLICT    $globalAgentsPath (legacy singleton protocol requires manual migration)"
    if ($Apply) {
        throw 'Refusing to replace a legacy global AGENTS.md automatically. Remove its positive legacy routing instructions, then rerun the installer.'
    }
}
else {
    Set-ManagedBlock -Path $globalAgentsPath -Block $globalBlock `
        -StartMarker '<!-- research-multiagent-orchestrator-global:start -->' `
        -EndMarker '<!-- research-multiagent-orchestrator-global:end -->'
}
}

foreach ($relative in @('.codex', '.codex\tasks', '.codex\bindings',
        '.codex\diagnostics', 'work', 'work\worker_state')) {
    Ensure-Directory (Join-Path $ProjectRoot $relative)
}

$modelMapPath = Join-Path $ProjectRoot '.codex\mygo-model-map.json'
$defaultModelMapPath = Join-Path $AssetRoot 'project\mygo-model-map.json'
if (-not (Test-Path -LiteralPath $modelMapPath -PathType Leaf)) {
    Add-Action "CREATE      $modelMapPath"
    if ($Apply) {
        $modelMapText = Get-Content -LiteralPath $defaultModelMapPath -Raw -Encoding UTF8
        Write-AtomicText $modelMapPath $modelMapText
    }
}
else {
    Add-Action "PRESERVE    $modelMapPath"
}

$descriptorPath = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
$rootForToml = $ProjectRoot.Replace('\', '/')
$descriptor = @"
canonical_root = "$rootForToml"
task_directory = "$rootForToml/.codex/tasks"
binding_directory = "$rootForToml/.codex/bindings"
state_directory = "$rootForToml/work/worker_state"
protocol_version = 3
primary_profile_mode = "session-choice"
deepseek_enabled = $(((-not $LunaOnly).ToString().ToLowerInvariant()))
model_map = "$rootForToml/.codex/mygo-model-map.json"
model_map_schema = 1
installation_scope = "$(if ($ProjectOnly) { 'project-only' } else { 'user-and-project' })"
"@
$oldDescriptor = if (Test-Path -LiteralPath $descriptorPath) {
    Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8
} else { '' }
if ($descriptor.Trim() -cne $oldDescriptor.Trim()) {
    Add-Action "UPDATE      $descriptorPath"
    if ($Apply) {
        Write-AtomicText $descriptorPath ($descriptor.Trim() + "`r`n")
    }
}

$projectAsset = if ($LunaOnly) { 'project\AGENTS.luna-only.block.md' } else { 'project\AGENTS.block.md' }
$agentsBlock = Get-Content -LiteralPath (Join-Path $AssetRoot $projectAsset) -Raw -Encoding UTF8
Set-ManagedBlock -Path (Join-Path $ProjectRoot 'AGENTS.md') -Block $agentsBlock `
    -StartMarker '<!-- research-multiagent-orchestrator:start -->' `
    -EndMarker '<!-- research-multiagent-orchestrator:end -->'

$ignoreBlock = Get-Content -LiteralPath (Join-Path $AssetRoot 'project\gitignore.block.txt') -Raw -Encoding UTF8
Set-ManagedBlock -Path (Join-Path $ProjectRoot '.gitignore') -Block $ignoreBlock `
    -StartMarker '# research-multiagent-orchestrator:start' `
    -EndMarker '# research-multiagent-orchestrator:end'

if (-not $LunaOnly -and -not $deepSeekKeyPresent) {
    Add-Action 'ACTION      DEEPSEEK_API_KEY is missing; apply will stop before writing'
    Add-Action 'ACTION      Run scripts\set-deepseek-key.ps1 interactively, restart Codex, or explicitly choose -LunaOnly'
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY_RUN' }
Write-Output "MODE=$mode"
Write-Output "INSTALL_SCOPE=$(if ($ProjectOnly) { 'PROJECT_ONLY' } else { 'USER_AND_PROJECT' })"
Write-Output "DEEPSEEK_MODE=$(if ($LunaOnly) { 'DISABLED' } elseif ($deepSeekKeyPresent) { 'ENABLED' } else { 'PENDING_KEY' })"
$Actions | ForEach-Object { Write-Output $_ }
if (-not $Apply) {
    Write-Output 'No files were changed. Review the plan and rerun with -Apply.'
}
else {
    $TransactionCommitted = $true
    Write-Output 'INSTALL_RESULT=PASS'
    Write-Output 'Fully restart Codex Desktop before using the installed agents.'
}
if ($installMutexAcquired) { $installMutex.ReleaseMutex(); $installMutexAcquired = $false }
$installMutex.Dispose()
$installMutex = $null
