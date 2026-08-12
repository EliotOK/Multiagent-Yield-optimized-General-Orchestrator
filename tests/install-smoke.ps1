[CmdletBinding()]
param([string]$RepositoryRoot = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$SkillRoot = Join-Path $RepositoryRoot 'research-multiagent-orchestrator'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rmo-release-smoke-' + [guid]::NewGuid().ToString('N'))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'

try {
    $testProject = Join-Path $testRoot 'project'
    $testCodex = Join-Path $testRoot 'codex-home'
    New-Item -ItemType Directory -Path $testProject -Force | Out-Null

    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $testProject -CodexHome $testCodex -ForceAgentUpdate -Apply
    if (-not $?) { throw 'Installer smoke test failed.' }

    $taskOutput = & (Join-Path $SkillRoot 'scripts\create-task.ps1') `
        -ProjectRoot $testProject -Worker luna_medium_worker `
        -Objective 'Release smoke test. No worker is spawned.'
    $taskId = ($taskOutput | Where-Object { $_ -like 'TASK_ID=*' } | Select-Object -First 1) -replace '^TASK_ID=', ''
    if ([string]::IsNullOrWhiteSpace($taskId)) { throw 'create-task did not return TASK_ID.' }

    $bindingPath = Join-Path $testProject ".codex\bindings\$taskId.json"
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
    if ($binding.worker_name -ne 'luna_medium_worker' -or $binding.protocol_version -ne 3) {
        throw 'create-task binding did not preserve the expected worker and protocol version.'
    }

    & (Join-Path $SkillRoot 'scripts\close-task.ps1') `
        -ProjectRoot $testProject -TaskId $taskId -Outcome INTERRUPTED `
        -ConfirmWorkerStopped -Apply
    if (-not $?) { throw 'close-task smoke test failed.' }

    $legacyCodex = Join-Path $testRoot 'legacy-codex-home'
    New-Item -ItemType Directory -Path $legacyCodex -Force | Out-Null
    $legacyGlobal = Join-Path $legacyCodex 'AGENTS.md'
    [IO.File]::WriteAllText($legacyGlobal, 'Use the `deepseek_worker` custom subagent.' + [Environment]::NewLine)
    $legacyBlocked = $false
    try {
        & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
            -ProjectRoot $testProject -CodexHome $legacyCodex -Apply
    }
    catch {
        $legacyBlocked = $true
    }
    if (-not $legacyBlocked) { throw 'Installer did not refuse unsafe legacy global migration.' }
    if ((Get-Content -LiteralPath $legacyGlobal -Raw) -notmatch 'deepseek_worker') {
        throw 'Unsafe legacy migration modified AGENTS.md despite refusal.'
    }

    $lunaProject = Join-Path $testRoot 'luna-project'
    $lunaCodex = Join-Path $testRoot 'luna-codex-home'
    New-Item -ItemType Directory -Path $lunaProject -Force | Out-Null
    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $lunaProject -CodexHome $lunaCodex -LunaOnly -Apply
    if (-not $?) { throw 'Luna-only installer smoke test failed.' }
    if (Test-Path -LiteralPath (Join-Path $lunaCodex 'agents\deepseek-context-worker.toml')) {
        throw 'Luna-only mode installed a DeepSeek worker.'
    }
    if ((Get-Content -LiteralPath (Join-Path $lunaCodex 'config.toml') -Raw) -match
        '\[model_providers\.deepseek\]') {
        throw 'Luna-only mode configured the DeepSeek provider.'
    }
    & (Join-Path $SkillRoot 'scripts\verify-workflow.ps1') `
        -ProjectRoot $lunaProject -CodexHome $lunaCodex -LunaOnly
    if (-not $?) { throw 'Luna-only verification failed.' }
    $deepSeekRejected = $false
    try {
        & (Join-Path $SkillRoot 'scripts\create-task.ps1') `
            -ProjectRoot $lunaProject -Worker deepseek_context_worker `
            -Objective 'This task must be rejected.'
    }
    catch { $deepSeekRejected = $true }
    if (-not $deepSeekRejected) { throw 'Luna-only mode did not block DeepSeek task creation.' }

    $projectOnlyRoot = Join-Path $testRoot 'project-only'
    $untouchedCodex = Join-Path $testRoot 'untouched-codex-home'
    New-Item -ItemType Directory -Path $projectOnlyRoot -Force | Out-Null
    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $projectOnlyRoot -CodexHome $untouchedCodex `
        -LunaOnly -ProjectOnly -Apply
    if (-not $?) { throw 'Project-only installer smoke test failed.' }
    if (Test-Path -LiteralPath $untouchedCodex) {
        throw 'Project-only mode created or modified the supplied Codex home.'
    }
    & (Join-Path $SkillRoot 'scripts\verify-workflow.ps1') `
        -ProjectRoot $projectOnlyRoot -CodexHome $untouchedCodex `
        -LunaOnly -ProjectOnly
    if (-not $?) { throw 'Project-only verification failed.' }

    Write-Output 'INSTALL_SMOKE=PASS'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
