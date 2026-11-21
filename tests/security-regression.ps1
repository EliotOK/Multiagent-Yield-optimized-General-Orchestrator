[CmdletBinding()]
param([string]$RepositoryRoot = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$SkillRoot = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'mygo'
$install = Join-Path $SkillRoot 'scripts\install-workflow.ps1'
$create = Join-Path $SkillRoot 'scripts\create-task.ps1'
$update = Join-Path $SkillRoot 'scripts\update-task-state.ps1'
$close = Join-Path $SkillRoot 'scripts\close-task.ps1'
$preflight = Join-Path $SkillRoot 'scripts\worker-preflight.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('mygo-security-' + [guid]::NewGuid().ToString('N'))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$originalKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'Process')

function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $failed = $false
    try { & $Action }
    catch { $failed = $_.Exception.Message -match $Pattern }
    if (-not $failed) { throw "Expected failure matching: $Pattern" }
}

try {
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', 'security-test-placeholder', 'Process')
    $project = Join-Path $root 'project'
    $codex = Join-Path $root 'codex'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    & $install -ProjectRoot $project -CodexHome $codex -Apply | Out-Null
    $primaryObservation = @{
        ObservedPrimaryModel = 'gpt-5.6-sol'
        ObservedPrimaryEffort = 'high'
    }
    [IO.File]::WriteAllText((Join-Path $project '.codex\tasks\README.md'), 'Task directory documentation.')

    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker luna_medium_worker `
            -Objective 'missing boundary'
    } 'AllowedFiles'
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker luna_medium_worker `
            -Objective 'escape' -AllowedFiles '..\outside.txt' -ValidationCommands 'node --version'
    } 'outside the project root'
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker terra_fallback_worker `
            -Objective 'invalid fallback' -Mode READ_ONLY
    } 'write-capable fallback'
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker deepseek_context_worker `
            -Objective 'sensitive external route' -Mode READ_ONLY
    } 'external provider'
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker astra_review_worker `
            -Objective 'wrong primary reviewer' -PrimaryProfile ASTRA
    } 'does not match current-session profile SOL'
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker sol_review_worker `
            -Objective 'wrong primary reviewer' -PrimaryProfile SOL
    } 'requires PrimaryProfile ASTRA'

    $taskOutput = & $create @primaryObservation -ProjectRoot $project -Worker luna_medium_worker `
        -Objective "Heading text is quoted`n## not a control section" `
        -AllowedFiles 'outputs/result.txt' -ValidationCommands 'node --version'
    $taskId = (($taskOutput | Where-Object { $_ -like 'TASK_ID=*' }) -replace '^TASK_ID=', '')
    $taskPath = Join-Path $project ".codex\tasks\$taskId.md"
    $taskHash = (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()

    Expect-Failure {
        & $update -ProjectRoot $project -TaskId $taskId -NewState AGENT_COMPLETED
    } 'Illegal task-state transition'
    & $update -ProjectRoot $project -TaskId $taskId -NewState AGENT_CREATED | Out-Null
    & $update -ProjectRoot $project -TaskId $taskId -NewState RUNNING | Out-Null
    & $update -ProjectRoot $project -TaskId $taskId -NewState OUTPUT_READY | Out-Null
    & $update -ProjectRoot $project -TaskId $taskId -NewState AGENT_COMPLETED | Out-Null
    $heldStateLockPath = Join-Path $project "work\worker_state\$taskId.state.lock"
    $heldStateLock = [IO.File]::Open($heldStateLockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Expect-Failure {
            & $close -ProjectRoot $project -TaskId $taskId -Outcome REVIEWED `
                -ConfirmWorkerStopped -Apply
        } 'lifecycle or state update is still active'
    }
    finally { $heldStateLock.Dispose() }
    & $close -ProjectRoot $project -TaskId $taskId -Outcome REVIEWED `
        -ConfirmWorkerStopped -Apply | Out-Null
    $archive = Join-Path $project ".codex\diagnostics\task-history\$taskId"
    $archivedHash = (Get-FileHash -LiteralPath (Join-Path $archive 'task.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    $archivedBinding = Get-Content -LiteralPath (Join-Path $archive 'binding.json') -Raw | ConvertFrom-Json
    if ($archivedHash -ne $taskHash -or $archivedHash -ne $archivedBinding.task_sha256) {
        throw 'Archived immutable task hash was not preserved.'
    }
    $archivedStatePath = Join-Path $archive 'state.json'
    $archivedStateOriginal = Get-Content -LiteralPath $archivedStatePath -Raw
    [IO.File]::WriteAllText($archivedStatePath, '{corrupt')
    Expect-Failure {
        & $close -ProjectRoot $project -TaskId $taskId -Outcome REVIEWED `
            -ConfirmWorkerStopped -Apply
    } 'JSON|Unexpected character|invalid'
    [IO.File]::WriteAllText($archivedStatePath, $archivedStateOriginal)

    $currentDescriptorPath = Join-Path $project '.codex\mygo.toml'
    $projectLegacyDescriptorPath = Join-Path $project '.codex\research-multiagent.toml'
    Move-Item -LiteralPath $currentDescriptorPath -Destination $projectLegacyDescriptorPath
    $legacyTaskOutput = & $create @primaryObservation -ProjectRoot $project -Worker luna_medium_worker `
        -Objective 'legacy task compatibility' -AllowedFiles 'outputs/legacy.txt' `
        -ValidationCommands 'node --version'
    $currentLegacyId = (($legacyTaskOutput | Where-Object { $_ -like 'TASK_ID=*' }) -replace '^TASK_ID=', '')
    if ($currentLegacyId -notmatch '^mygo-') { throw 'Compatibility fixture was not created with a mygo ID.' }
    $legacyId = 'rmo-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $currentTaskPath = Join-Path $project ".codex\tasks\$currentLegacyId.md"
    $currentBindingPath = Join-Path $project ".codex\bindings\$currentLegacyId.json"
    $currentStatePath = Join-Path $project "work\worker_state\$currentLegacyId.json"
    $legacyTaskPath = Join-Path $project ".codex\tasks\$legacyId.md"
    $legacyBindingPath = Join-Path $project ".codex\bindings\$legacyId.json"
    $legacyStatePath = Join-Path $project "work\worker_state\$legacyId.json"
    Move-Item -LiteralPath $currentTaskPath -Destination $legacyTaskPath
    Move-Item -LiteralPath $currentBindingPath -Destination $legacyBindingPath
    Move-Item -LiteralPath $currentStatePath -Destination $legacyStatePath

    $legacyTaskText = (Get-Content -LiteralPath $legacyTaskPath -Raw -Encoding UTF8).Replace(
        "Task ID: $currentLegacyId", "Task ID: $legacyId")
    [IO.File]::WriteAllText($legacyTaskPath, $legacyTaskText, [Text.UTF8Encoding]::new($false))
    $legacyTaskHash = (Get-FileHash -LiteralPath $legacyTaskPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $legacyBinding = Get-Content -LiteralPath $legacyBindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $legacyBinding.task_id = $legacyId
    $legacyBinding.task_path = $legacyTaskPath
    $legacyBinding.state_path = $legacyStatePath
    $legacyBinding.task_sha256 = $legacyTaskHash
    [IO.File]::WriteAllText($legacyBindingPath, ($legacyBinding | ConvertTo-Json -Depth 8) + "`r`n",
        [Text.UTF8Encoding]::new($false))
    $legacyState = Get-Content -LiteralPath $legacyStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $legacyState.task_id = $legacyId
    [IO.File]::WriteAllText($legacyStatePath, ($legacyState | ConvertTo-Json -Depth 8) + "`r`n",
        [Text.UTF8Encoding]::new($false))
    & $update -ProjectRoot $project -TaskId $legacyId -NewState INTERRUPTED | Out-Null
    & $close -ProjectRoot $project -TaskId $legacyId -Outcome INTERRUPTED `
        -ConfirmWorkerStopped -Apply | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $project ".codex\diagnostics\task-history\$legacyId\task.md"))) {
        throw 'Legacy rmo task was not archived by close-task.'
    }
    Move-Item -LiteralPath $projectLegacyDescriptorPath -Destination $currentDescriptorPath

    $failedOutput = & $create @primaryObservation -ProjectRoot $project -Worker luna_medium_worker `
        -Objective 'produce fallback evidence' -AllowedFiles 'outputs/failed.txt' `
        -ValidationCommands 'node --version'
    $failedId = (($failedOutput | Where-Object { $_ -like 'TASK_ID=*' }) -replace '^TASK_ID=', '')
    & $update -ProjectRoot $project -TaskId $failedId -NewState FAILED | Out-Null
    & $close -ProjectRoot $project -TaskId $failedId -Outcome FAILED `
        -ConfirmWorkerStopped -Apply | Out-Null
    $fallbackOutput = & $create @primaryObservation -ProjectRoot $project `
        -Worker terra_readonly_fallback_worker -Objective 'read-only reconstruction' `
        -PreviousFailureTaskId $failedId
    $fallbackId = (($fallbackOutput | Where-Object { $_ -like 'TASK_ID=*' }) -replace '^TASK_ID=', '')
    $fallbackBindingPath = Join-Path $project ".codex\bindings\$fallbackId.json"
    $fallbackBinding = Get-Content -LiteralPath $fallbackBindingPath -Raw | ConvertFrom-Json
    if ($fallbackBinding.mode -ne 'READ_ONLY') { throw 'Read-only Terra fallback was not hard-bound to READ_ONLY.' }
    $fallbackBinding.status = 'REVIEWED'
    [IO.File]::WriteAllText($fallbackBindingPath, ($fallbackBinding | ConvertTo-Json -Depth 8))
    $preflightFailed = $false
    try { & $preflight -ProjectRoot $project -CodexHome $codex -TaskId $fallbackId | Out-Null }
    catch { $preflightFailed = $true }
    if (-not $preflightFailed) { throw 'Preflight accepted a non-READY requested binding.' }
    $fallbackBinding.status = 'READY'
    [IO.File]::WriteAllText($fallbackBindingPath, ($fallbackBinding | ConvertTo-Json -Depth 8))
    & $update -ProjectRoot $project -TaskId $fallbackId -NewState INTERRUPTED | Out-Null
    & $close -ProjectRoot $project -TaskId $fallbackId -Outcome INTERRUPTED `
        -ConfirmWorkerStopped -Apply | Out-Null

    $tamperOutput = & $create @primaryObservation -ProjectRoot $project -Worker luna_medium_worker `
        -Objective 'tamper detection' -AllowedFiles 'outputs/tamper.txt' `
        -ValidationCommands 'node --version'
    $tamperId = (($tamperOutput | Where-Object { $_ -like 'TASK_ID=*' }) -replace '^TASK_ID=', '')
    $tamperTask = Join-Path $project ".codex\tasks\$tamperId.md"
    Add-Content -LiteralPath $tamperTask -Value 'tampered'
    Expect-Failure {
        & $close -ProjectRoot $project -TaskId $tamperId -Outcome INTERRUPTED `
            -ConfirmWorkerStopped -Apply
    } 'Task hash mismatch'
    Remove-Item -LiteralPath (Join-Path $project ".codex\bindings\$tamperId.json") -Force
    Remove-Item -LiteralPath $tamperTask -Force
    Remove-Item -LiteralPath (Join-Path $project "work\worker_state\$tamperId.json") -Force

    $descriptorPath = Join-Path $project '.codex\mygo.toml'
    $descriptorOriginal = Get-Content -LiteralPath $descriptorPath -Raw
    [IO.File]::WriteAllText($descriptorPath, ($descriptorOriginal -replace 'protocol_version = 4', 'protocol_version = 999'))
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $project -Worker deepseek_context_worker `
            -Objective 'descriptor tamper' -Mode READ_ONLY -DataSensitivity PUBLIC
    } 'protocol version'
    [IO.File]::WriteAllText($descriptorPath, $descriptorOriginal)

    $concurrentProject = Join-Path $root 'concurrent-project'
    $concurrentCodex = Join-Path $root 'concurrent-codex'
    New-Item -ItemType Directory -Path $concurrentProject -Force | Out-Null
    & $install -ProjectRoot $concurrentProject -CodexHome $concurrentCodex -LunaOnly -Apply | Out-Null
    $jobScript = {
        param($CreateScript, $Project)
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $CreateScript `
            -ProjectRoot $Project -Worker luna_medium_worker -Objective concurrent `
            -AllowedFiles outputs/result.txt -ValidationCommands 'node --version' `
            -ObservedPrimaryModel gpt-5.6-sol -ObservedPrimaryEffort high
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    $jobs = @(Start-Job -ScriptBlock $jobScript -ArgumentList $create, $concurrentProject
        Start-Job -ScriptBlock $jobScript -ArgumentList $create, $concurrentProject)
    $jobs | Wait-Job | Out-Null
    $jobResults = @($jobs | Receive-Job -ErrorAction SilentlyContinue)
    $successCount = @($jobResults | Where-Object {
        $_.ExitCode -eq 0 -and @($_.Output | Where-Object { $_ -like 'TASK_ID=*' }).Count -eq 1
    }).Count
    $jobs | Remove-Job -Force
    if ($successCount -ne 1) { throw "Concurrent creation allowed $successCount successful tasks; expected 1." }
    if (@(Get-ChildItem -LiteralPath (Join-Path $concurrentProject '.codex\bindings') -Filter '*.json').Count -ne 1) {
        throw 'Concurrent creation did not leave exactly one binding.'
    }

    $orphanProject = Join-Path $root 'orphan-project'
    $orphanCodex = Join-Path $root 'orphan-codex'
    New-Item -ItemType Directory -Path $orphanProject -Force | Out-Null
    & $install -ProjectRoot $orphanProject -CodexHome $orphanCodex -LunaOnly -Apply | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $orphanProject '.codex\tasks\rmo-20260101-000000-deadbeef.md'),
        'legacy crash remnant')
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $orphanProject -Worker luna_medium_worker `
            -Objective 'must not bypass orphan' -AllowedFiles 'outputs/result.txt' `
            -ValidationCommands 'node --version'
    } 'Orphan coordination artifacts'

    $orphanTempProject = Join-Path $root 'orphan-temp-project'
    $orphanTempCodex = Join-Path $root 'orphan-temp-codex'
    New-Item -ItemType Directory -Path $orphanTempProject -Force | Out-Null
    & $install -ProjectRoot $orphanTempProject -CodexHome $orphanTempCodex -LunaOnly -Apply | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $orphanTempProject '.codex\tasks\mygo-crash-remnant.md.rmo-tmp'),
        'legacy temporary remnant')
    Expect-Failure {
        & $create @primaryObservation -ProjectRoot $orphanTempProject -Worker luna_medium_worker `
            -Objective 'must detect the legacy temporary suffix' -AllowedFiles 'outputs/result.txt' `
            -ValidationCommands 'node --version'
    } 'Orphan coordination artifacts'

    $migrationProject = Join-Path $root 'migration-project'
    $migrationCodex = Join-Path $root 'migration-codex'
    New-Item -ItemType Directory -Path (Join-Path $migrationProject '.codex') -Force | Out-Null
    New-Item -ItemType Directory -Path $migrationCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $migrationProject '.codex\research-multiagent.toml'),
        "canonical_root = `"legacy fixture`"`r`nprotocol_version = 4`r`n")
    [IO.File]::WriteAllText((Join-Path $migrationProject 'AGENTS.md'),
        "before agents`r`n<!-- research-multiagent-orchestrator:start -->`r`nlegacy project block`r`n<!-- research-multiagent-orchestrator:end -->`r`nafter agents`r`n")
    [IO.File]::WriteAllText((Join-Path $migrationProject '.gitignore'),
        "before ignore`r`n# research-multiagent-orchestrator:start`r`nlegacy ignore block`r`n# research-multiagent-orchestrator:end`r`nafter ignore`r`n")
    [IO.File]::WriteAllText((Join-Path $migrationCodex 'AGENTS.md'),
        "before global`r`n<!-- research-multiagent-orchestrator-global:start -->`r`nlegacy global block`r`n<!-- research-multiagent-orchestrator-global:end -->`r`nafter global`r`n")
    & $install -ProjectRoot $migrationProject -CodexHome $migrationCodex -LunaOnly -Apply | Out-Null
    if (Test-Path -LiteralPath (Join-Path $migrationProject '.codex\research-multiagent.toml')) {
        throw 'Legacy descriptor was not migrated and removed.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $migrationProject '.codex\mygo.toml') -PathType Leaf)) {
        throw 'Current descriptor was not created during migration.'
    }
    $migrationAgents = Get-Content -LiteralPath (Join-Path $migrationProject 'AGENTS.md') -Raw
    $migrationIgnore = Get-Content -LiteralPath (Join-Path $migrationProject '.gitignore') -Raw
    $migrationGlobal = Get-Content -LiteralPath (Join-Path $migrationCodex 'AGENTS.md') -Raw
    if ($migrationAgents -notmatch '<!-- mygo:start -->' -or
        $migrationAgents -match 'research-multiagent-orchestrator:start' -or
        $migrationAgents -notmatch 'before agents' -or $migrationAgents -notmatch 'after agents') {
        throw 'Legacy project AGENTS marker was not migrated without losing surrounding text.'
    }
    if ($migrationIgnore -notmatch '# mygo:start' -or
        $migrationIgnore -match 'research-multiagent-orchestrator:start' -or
        $migrationIgnore -notmatch 'before ignore' -or $migrationIgnore -notmatch 'after ignore') {
        throw 'Legacy .gitignore marker was not migrated without losing surrounding text.'
    }
    if ($migrationGlobal -notmatch '<!-- mygo-global:start -->' -or
        $migrationGlobal -match 'research-multiagent-orchestrator-global:start' -or
        $migrationGlobal -notmatch 'before global' -or $migrationGlobal -notmatch 'after global') {
        throw 'Legacy global AGENTS marker was not migrated without losing surrounding text.'
    }
    $legacyBackup = @(Get-ChildItem -LiteralPath (Join-Path $migrationProject '.codex\diagnostics\backups') `
        -Filter 'research-multiagent.toml.mygo-backup-*' -File)
    if ($legacyBackup.Count -ne 1) {
        throw 'Legacy descriptor migration did not create exactly one mygo backup.'
    }

    $conflictProject = Join-Path $root 'descriptor-conflict-project'
    $conflictCodex = Join-Path $root 'descriptor-conflict-codex'
    New-Item -ItemType Directory -Path $conflictProject -Force | Out-Null
    & $install -ProjectRoot $conflictProject -CodexHome $conflictCodex -LunaOnly -Apply | Out-Null
    $conflictCurrent = Join-Path $conflictProject '.codex\mygo.toml'
    $conflictLegacy = Join-Path $conflictProject '.codex\research-multiagent.toml'
    $conflictCurrentHash = (Get-FileHash -LiteralPath $conflictCurrent -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($conflictLegacy,
        ((Get-Content -LiteralPath $conflictCurrent -Raw -Encoding UTF8) + "`r`n# conflicting legacy descriptor`r`n"),
        [Text.UTF8Encoding]::new($false))
    Expect-Failure {
        & $install -ProjectRoot $conflictProject -CodexHome $conflictCodex -LunaOnly -Apply
    } 'different content'
    if ((Get-FileHash -LiteralPath $conflictCurrent -Algorithm SHA256).Hash -ne $conflictCurrentHash) {
        throw 'Conflicting legacy descriptor changed the current descriptor before aborting.'
    }

    $badProject = Join-Path $root 'bad-project'
    $badCodex = Join-Path $root 'bad-codex'
    New-Item -ItemType Directory -Path $badProject -Force | Out-Null
    New-Item -ItemType Directory -Path $badCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $badCodex 'config.toml'), "[agents]`r`nenabled=true`r`n[agents]`r`nenabled=false`r`n")
    Expect-Failure {
        & $install -ProjectRoot $badProject -CodexHome $badCodex -LunaOnly -Apply
    } 'Duplicate TOML section'
    if (Test-Path -LiteralPath (Join-Path $badProject '.codex')) {
        throw 'Ambiguous TOML failure wrote to the project.'
    }

    $multilineProject = Join-Path $root 'multiline-project'
    $multilineCodex = Join-Path $root 'multiline-codex'
    New-Item -ItemType Directory -Path $multilineProject -Force | Out-Null
    New-Item -ItemType Directory -Path $multilineCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $multilineCodex 'config.toml'),
        "[agents]`r`nnote = `"`"`"`r`nenabled = false`r`n`"`"`"`r`n")
    & $install -ProjectRoot $multilineProject -CodexHome $multilineCodex `
        -LunaOnly -ForceAgentUpdate -Apply | Out-Null
    $multilineConfig = Get-Content -LiteralPath (Join-Path $multilineCodex 'config.toml') -Raw
    if ($multilineConfig -notmatch '(?m)^enabled = true\s*$' -or
        $multilineConfig -notmatch '(?m)^enabled = false\s*$') {
        throw 'TOML multiline guard did not preserve string content and add a real setting.'
    }

    $incompatibleProject = Join-Path $root 'incompatible-project-only'
    New-Item -ItemType Directory -Path $incompatibleProject -Force | Out-Null
    $agentToCorrupt = Join-Path $codex 'agents\luna-medium-worker.toml'
    $agentOriginal = Get-Content -LiteralPath $agentToCorrupt -Raw
    [IO.File]::WriteAllText($agentToCorrupt, 'name = "wrong"')
    Expect-Failure {
        & $install -ProjectRoot $incompatibleProject -CodexHome $codex `
            -LunaOnly -ProjectOnly -Apply
    } 'incompatible agent'
    if (Test-Path -LiteralPath (Join-Path $incompatibleProject '.codex')) {
        throw 'Incompatible ProjectOnly prerequisite wrote to the project.'
    }
    [IO.File]::WriteAllText($agentToCorrupt, $agentOriginal)

    $markerProject = Join-Path $root 'marker-project'
    $markerCodex = Join-Path $root 'marker-codex'
    New-Item -ItemType Directory -Path $markerProject -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $markerProject 'AGENTS.md'),
        "<!-- research-multiagent-orchestrator:start -->`r`ntruncated`r`n")
    Expect-Failure {
        & $install -ProjectRoot $markerProject -CodexHome $markerCodex -LunaOnly -Apply
    } 'markers are incomplete'
    if (Test-Path -LiteralPath $markerCodex) {
        throw 'Marker preflight failure wrote to Codex home.'
    }

    $projectOnly = Join-Path $root 'project-only-missing'
    $emptyCodex = Join-Path $root 'empty-codex'
    New-Item -ItemType Directory -Path $projectOnly -Force | Out-Null
    Expect-Failure {
        & $install -ProjectRoot $projectOnly -CodexHome $emptyCodex `
            -LunaOnly -ProjectOnly -Apply
    } 'prerequisites are missing'
    if (Test-Path -LiteralPath (Join-Path $projectOnly '.codex')) {
        throw 'Project-only prerequisite failure wrote to the project.'
    }

    Write-Output 'SECURITY_REGRESSION=PASS'
}
finally {
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $originalKey, 'Process')
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
