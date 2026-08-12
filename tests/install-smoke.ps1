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
    $originalProcessKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'Process')
    $missingKeyProject = Join-Path $testRoot 'missing-key-project'
    $missingKeyCodex = Join-Path $testRoot 'missing-key-codex-home'
    New-Item -ItemType Directory -Path $missingKeyProject -Force | Out-Null
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $null, 'Process')
    $userKeyForTest = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
    if ([string]::IsNullOrWhiteSpace($userKeyForTest)) {
        $missingKeyBlocked = $false
        try {
            & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
                -ProjectRoot $missingKeyProject -CodexHome $missingKeyCodex -Apply
        }
        catch {
            $missingKeyBlocked = $_.Exception.Message -match 'set-deepseek-key\.ps1'
        }
        if (-not $missingKeyBlocked) {
            throw 'Full-mode apply did not stop with secure key setup guidance.'
        }
        if (Test-Path -LiteralPath $missingKeyCodex) {
            throw 'Missing-key full-mode apply wrote to Codex home before stopping.'
        }
        if (Test-Path -LiteralPath (Join-Path $missingKeyProject '.codex')) {
            throw 'Missing-key full-mode apply wrote to the project before stopping.'
        }
    }
    $userKeyForTest = $null
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', 'release-smoke-placeholder', 'Process')
    $testProject = Join-Path $testRoot 'project'
    $testCodex = Join-Path $testRoot 'codex-home'
    New-Item -ItemType Directory -Path $testProject -Force | Out-Null

    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $testProject -CodexHome $testCodex -ForceAgentUpdate -Apply
    if (-not $?) { throw 'Installer smoke test failed.' }

    $initialSnapshot = @(Get-ChildItem -LiteralPath $testProject, $testCodex -Recurse -File | ForEach-Object {
        "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $testProject -CodexHome $testCodex -ForceAgentUpdate -Apply | Out-Null
    $idempotentSnapshot = @(Get-ChildItem -LiteralPath $testProject, $testCodex -Recurse -File | ForEach-Object {
        "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
    if (($initialSnapshot -join "`n") -cne ($idempotentSnapshot -join "`n")) {
        throw 'Idempotent reinstall changed installed files.'
    }

    $taskOutput = & (Join-Path $SkillRoot 'scripts\create-task.ps1') `
        -ProjectRoot $testProject -Worker luna_medium_worker `
        -Objective 'Release smoke test. No worker is spawned.' `
        -AllowedFiles 'outputs/smoke.txt' -ValidationCommands 'node --version'
    $taskId = ($taskOutput | Where-Object { $_ -like 'TASK_ID=*' } | Select-Object -First 1) -replace '^TASK_ID=', ''
    if ([string]::IsNullOrWhiteSpace($taskId)) { throw 'create-task did not return TASK_ID.' }

    $bindingPath = Join-Path $testProject ".codex\bindings\$taskId.json"
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
    if ($binding.worker_name -ne 'luna_medium_worker' -or $binding.protocol_version -ne 3) {
        throw 'create-task binding did not preserve the expected worker and protocol version.'
    }

    & (Join-Path $SkillRoot 'scripts\update-task-state.ps1') `
        -ProjectRoot $testProject -TaskId $taskId -NewState INTERRUPTED | Out-Null
    & (Join-Path $SkillRoot 'scripts\close-task.ps1') `
        -ProjectRoot $testProject -TaskId $taskId -Outcome INTERRUPTED `
        -ConfirmWorkerStopped -Apply
    if (-not $?) { throw 'close-task smoke test failed.' }
    & git -C $testProject init --quiet
    foreach ($ignoredPath in @('.codex/research-multiagent.toml',
            ".codex/diagnostics/task-history/$taskId/task.md")) {
        & git -C $testProject check-ignore --quiet -- $ignoredPath
        if ($LASTEXITCODE -ne 0) { throw "Generated private artifact is not gitignored: $ignoredPath" }
    }

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
    New-Item -ItemType Directory -Path $projectOnlyRoot -Force | Out-Null
    $codexSnapshotBefore = @(Get-ChildItem -LiteralPath $lunaCodex -Recurse -File | ForEach-Object {
        "$($_.FullName.Substring($lunaCodex.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $projectOnlyRoot -CodexHome $lunaCodex `
        -LunaOnly -ProjectOnly -Apply
    if (-not $?) { throw 'Project-only installer smoke test failed.' }
    $codexSnapshotAfter = @(Get-ChildItem -LiteralPath $lunaCodex -Recurse -File | ForEach-Object {
        "$($_.FullName.Substring($lunaCodex.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
    if (($codexSnapshotBefore -join "`n") -cne ($codexSnapshotAfter -join "`n")) {
        throw 'Project-only mode modified the supplied Codex home.'
    }
    & (Join-Path $SkillRoot 'scripts\verify-workflow.ps1') `
        -ProjectRoot $projectOnlyRoot -CodexHome $lunaCodex `
        -LunaOnly -ProjectOnly
    if (-not $?) { throw 'Project-only verification failed.' }

    $fullProjectOnlyRoot = Join-Path $testRoot 'full-project-only'
    New-Item -ItemType Directory -Path $fullProjectOnlyRoot -Force | Out-Null
    $fullCodexBefore = @(Get-ChildItem -LiteralPath $testCodex -Recurse -File | ForEach-Object {
        "$($_.FullName.Substring($testCodex.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
    & (Join-Path $SkillRoot 'scripts\install-workflow.ps1') `
        -ProjectRoot $fullProjectOnlyRoot -CodexHome $testCodex -ProjectOnly -Apply
    if (-not $?) { throw 'Full project-only installer smoke test failed.' }
    & (Join-Path $SkillRoot 'scripts\verify-workflow.ps1') `
        -ProjectRoot $fullProjectOnlyRoot -CodexHome $testCodex -ProjectOnly
    if (-not $?) { throw 'Full project-only verification failed.' }
    $fullCodexAfter = @(Get-ChildItem -LiteralPath $testCodex -Recurse -File | ForEach-Object {
        "$($_.FullName.Substring($testCodex.Length))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object)
    if (($fullCodexBefore -join "`n") -cne ($fullCodexAfter -join "`n")) {
        throw 'Full project-only mode modified user-level Codex files.'
    }

    Write-Output 'INSTALL_SMOKE=PASS'
}
finally {
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $originalProcessKey, 'Process')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
