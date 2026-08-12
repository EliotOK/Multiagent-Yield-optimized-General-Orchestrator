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

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $ProjectRoot"
}

$processKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'Process')
$userKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
$deepSeekKeyPresent = -not [string]::IsNullOrWhiteSpace($processKey) -or
    -not [string]::IsNullOrWhiteSpace($userKey)
$processKey = $null
$userKey = $null
if (-not $LunaOnly -and -not $ProjectOnly -and -not $deepSeekKeyPresent -and $Apply) {
    throw 'DEEPSEEK_API_KEY is missing. No files were changed. Run scripts\set-deepseek-key.ps1 in an interactive terminal, fully restart Codex, then retry; or explicitly use -LunaOnly.'
}

function Add-Action([string]$Message) {
    $script:Actions.Add($Message)
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Add-Action "CREATE DIR  $Path"
        if ($Apply) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    }
}

function Backup-File([string]$Path) {
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
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backup = Join-Path $backupRoot ((Split-Path -Leaf $Path) + ".rmo-backup-$stamp")
        Copy-Item -LiteralPath $Path -Destination $backup
        Add-Action "BACKUP      $backup"
    }
}

function Set-TomlSetting {
    param([string]$Text, [string]$Section, [string]$Key, [string]$Value)

    $sectionName = [regex]::Escape($Section)
    $sectionPattern = "(?ms)^\[$sectionName\][ \t]*\r?\n.*?(?=^\[|\z)"
    $sectionMatch = [regex]::Match($Text, $sectionPattern)
    if (-not $sectionMatch.Success) {
        $separator = if ([string]::IsNullOrWhiteSpace($Text)) { '' } else { "`r`n`r`n" }
        return $Text.TrimEnd() + $separator + "[$Section]`r`n$Key = $Value`r`n"
    }

    $block = $sectionMatch.Value
    $keyPattern = '(?m)^' + [regex]::Escape($Key) + '[ \t]*=.*$'
    if ([regex]::IsMatch($block, $keyPattern)) {
        $newBlock = [regex]::Replace($block, $keyPattern, "$Key = $Value", 1)
    }
    else {
        $newBlock = $block.TrimEnd() + "`r`n$Key = $Value`r`n"
    }
    return $Text.Substring(0, $sectionMatch.Index) + $newBlock +
        $Text.Substring($sectionMatch.Index + $sectionMatch.Length)
}

function Normalize-Newlines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ([regex]::Replace($Text, "\r\n|\r|\n", "`r`n")).TrimEnd() + "`r`n"
}

function Set-ManagedBlock {
    param(
        [string]$Path,
        [string]$Block,
        [string]$StartMarker,
        [string]$EndMarker
    )

    $old = if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } else { '' }
    $pattern = '(?ms)' + [regex]::Escape($StartMarker) + '.*?' +
        [regex]::Escape($EndMarker)
    if ([regex]::IsMatch($old, $pattern)) {
        $new = [regex]::Replace($old, $pattern, $Block.TrimEnd(), 1)
    }
    else {
        $prefix = if ([string]::IsNullOrWhiteSpace($old)) { '' } else { $old.TrimEnd() + "`r`n`r`n" }
        $new = $prefix + $Block.TrimEnd() + "`r`n"
    }
    if ($new -cne $old) {
        Add-Action "UPDATE      $Path"
        if ($Apply) {
            Backup-File $Path
            [IO.File]::WriteAllText($Path, $new, [Text.UTF8Encoding]::new($false))
        }
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
$newConfig = Set-TomlSetting $newConfig 'agents' 'max_concurrent_threads_per_session' '2'
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
        Backup-File $configPath
        [IO.File]::WriteAllText($configPath, $newConfig, [Text.UTF8Encoding]::new($false))
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
        if ($null -ne $targetText -and -not $ForceAgentUpdate) {
            Add-Action "CONFLICT    $target (rerun with -ForceAgentUpdate after review)"
            if ($Apply) { throw "Refusing to overwrite custom agent: $target" }
        }
        else {
            Add-Action "INSTALL     $target"
            if ($Apply) {
                Backup-File $target
                Copy-Item -LiteralPath $source.FullName -Destination $target -Force
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

$descriptorPath = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
$rootForToml = $ProjectRoot.Replace('\', '/')
$descriptor = @"
canonical_root = "$rootForToml"
task_directory = "$rootForToml/.codex/tasks"
binding_directory = "$rootForToml/.codex/bindings"
state_directory = "$rootForToml/work/worker_state"
protocol_version = 3
deepseek_enabled = $(((-not $LunaOnly) -and (-not $ProjectOnly)).ToString().ToLowerInvariant())
installation_scope = "$(if ($ProjectOnly) { 'project-only' } else { 'user-and-project' })"
"@
$oldDescriptor = if (Test-Path -LiteralPath $descriptorPath) {
    Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8
} else { '' }
if ($descriptor.Trim() -cne $oldDescriptor.Trim()) {
    Add-Action "UPDATE      $descriptorPath"
    if ($Apply) {
        Backup-File $descriptorPath
        [IO.File]::WriteAllText($descriptorPath, $descriptor.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))
    }
}

$projectAsset = if ($LunaOnly -or $ProjectOnly) { 'project\AGENTS.luna-only.block.md' } else { 'project\AGENTS.block.md' }
$agentsBlock = Get-Content -LiteralPath (Join-Path $AssetRoot $projectAsset) -Raw -Encoding UTF8
Set-ManagedBlock -Path (Join-Path $ProjectRoot 'AGENTS.md') -Block $agentsBlock `
    -StartMarker '<!-- research-multiagent-orchestrator:start -->' `
    -EndMarker '<!-- research-multiagent-orchestrator:end -->'

$ignoreBlock = Get-Content -LiteralPath (Join-Path $AssetRoot 'project\gitignore.block.txt') -Raw -Encoding UTF8
Set-ManagedBlock -Path (Join-Path $ProjectRoot '.gitignore') -Block $ignoreBlock `
    -StartMarker '# research-multiagent-orchestrator:start' `
    -EndMarker '# research-multiagent-orchestrator:end'

$key = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
if (-not $LunaOnly -and -not $ProjectOnly -and -not $deepSeekKeyPresent) {
    Add-Action 'ACTION      DEEPSEEK_API_KEY is missing; apply will stop before writing'
    Add-Action 'ACTION      Run scripts\set-deepseek-key.ps1 interactively, restart Codex, or explicitly choose -LunaOnly'
}
$key = $null

$mode = if ($Apply) { 'APPLY' } else { 'DRY_RUN' }
Write-Output "MODE=$mode"
Write-Output "INSTALL_SCOPE=$(if ($ProjectOnly) { 'PROJECT_ONLY' } else { 'USER_AND_PROJECT' })"
Write-Output "DEEPSEEK_MODE=$(if ($LunaOnly -or $ProjectOnly) { 'DISABLED' } elseif ($deepSeekKeyPresent) { 'ENABLED' } else { 'PENDING_KEY' })"
$Actions | ForEach-Object { Write-Output $_ }
if (-not $Apply) {
    Write-Output 'No files were changed. Review the plan and rerun with -Apply.'
}
else {
    Write-Output 'INSTALL_RESULT=PASS'
    Write-Output 'Fully restart Codex Desktop before using the installed agents.'
}
