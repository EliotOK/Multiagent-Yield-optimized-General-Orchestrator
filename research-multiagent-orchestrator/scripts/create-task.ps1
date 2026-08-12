[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('deepseek_context_worker', 'deepseek_context_reasoning_worker',
        'deepseek_batch_worker', 'luna_medium_worker', 'luna_high_worker',
        'luna_max_worker', 'terra_fallback_worker')]
    [string]$Worker,
    [Parameter(Mandatory = $true)]
    [string]$Objective,
    [string[]]$AllowedFiles = @(),
    [string[]]$ForbiddenActions = @(
        'Modify raw data', 'Commit or push', 'Change scientific assumptions',
        'Install system-wide dependencies', 'Modify task or binding files'
    ),
    [string[]]$ValidationCommands = @(),
    [int]$ExpectedMinutes = 0,
    [int]$FirstObservationSeconds = 30,
    [string]$PreviousFailureTaskId = ''
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $ProjectRoot"
}

$descriptor = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
if (-not (Test-Path -LiteralPath $descriptor)) {
    throw "Workflow is not installed in this project: $descriptor"
}
$descriptorText = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8
if ($Worker -like 'deepseek_*' -and
    $descriptorText -match '(?m)^deepseek_enabled\s*=\s*false\s*$') {
    throw "DeepSeek routing is disabled for this project. Reinstall explicitly without -LunaOnly or -ProjectOnly before creating $Worker tasks."
}

$taskDir = Join-Path $ProjectRoot '.codex\tasks'
$bindingDir = Join-Path $ProjectRoot '.codex\bindings'
$stateDir = Join-Path $ProjectRoot 'work\worker_state'
foreach ($dir in @($taskDir, $bindingDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Required directory is missing: $dir"
    }
}

$activeBindings = @(Get-ChildItem -LiteralPath $bindingDir -Filter '*.json' -File | Where-Object {
    try { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).status -eq 'READY' }
    catch { $true }
})
if ($activeBindings.Count -gt 0) {
    throw "An active or unreadable binding already exists. Finish it before creating another: $($activeBindings.FullName -join ', ')"
}

if ($ExpectedMinutes -le 0) {
    $ExpectedMinutes = switch ($Worker) {
        'deepseek_context_worker' { 5 }
        'deepseek_context_reasoning_worker' { 12 }
        'deepseek_batch_worker' { 6 }
        'luna_medium_worker' { 5 }
        'luna_high_worker' { 7 }
        'luna_max_worker' { 8 }
        default { 8 }
    }
}
if ($FirstObservationSeconds -lt 10) {
    throw 'FirstObservationSeconds must be at least 10.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$taskId = "rmo-$stamp-$suffix"
$taskPath = Join-Path $taskDir "$taskId.md"
$bindingPath = Join-Path $bindingDir "$taskId.json"
$statePath = Join-Path $stateDir "$taskId.json"
$mode = if ($Worker -like 'deepseek_context_*') { 'READ_ONLY' } else { 'WORKSPACE_WRITE' }

function Format-List([string[]]$Items, [string]$EmptyText) {
    if ($Items.Count -eq 0) { return "- $EmptyText" }
    return ($Items | ForEach-Object { "- $_" }) -join "`r`n"
}

$allowed = Format-List $AllowedFiles 'No writes allowed unless an explicit path is listed.'
$forbidden = Format-List $ForbiddenActions 'No additional forbidden actions.'
$validation = Format-List $ValidationCommands 'Return a read-only evidence report; no execution validation specified.'
$previous = if ([string]::IsNullOrWhiteSpace($PreviousFailureTaskId)) { 'None' } else { $PreviousFailureTaskId }
$created = (Get-Date).ToString('o')

$taskText = @"
Task ID: $taskId
Status: READY
Worker: $Worker
Mode: $mode
Canonical root: $ProjectRoot
Created: $created
Previous failure task: $previous
Expected duration minutes: $ExpectedMinutes
First observation seconds: $FirstObservationSeconds

## Objective

$Objective

## Allowed files

$allowed

## Coordination reads

- The exact task and binding paths supplied in the spawn message.
- `.codex/research-multiagent.toml` only if a required binding field is missing.

## Forbidden actions

$forbidden

## Acceptance criteria

- Stay inside the objective, mode, and allowed-file boundary.
- Preserve raw inputs and return concise file-path evidence.
- Report elapsed time and COMPLETE, FAILED, or BLOCKED.

## Validation commands

$validation

## Hard-stop evidence

- Explicit provider, process-exit, permission, or binding error; or two silent
  observation windows followed by confirmation that no process or write remains.

## Return contract

Return task ID, binding result, inspected/changed files, commands with exit codes,
elapsed time, status, and remaining risks. Keep the response compact.
"@

[IO.File]::WriteAllText($taskPath, $taskText.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))
$taskHash = (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()

$binding = [ordered]@{
    protocol_version = 3
    task_id = $taskId
    status = 'READY'
    worker_name = $Worker
    mode = $mode
    canonical_root = $ProjectRoot
    task_path = $taskPath
    task_sha256 = $taskHash
    state_path = $statePath
    created_at = $created
    expected_minutes = $ExpectedMinutes
    first_observation_seconds = $FirstObservationSeconds
    previous_failure_task_id = $PreviousFailureTaskId
    dispatch_epoch_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}
[IO.File]::WriteAllText(
    $bindingPath,
    ($binding | ConvertTo-Json -Depth 5) + "`r`n",
    [Text.UTF8Encoding]::new($false)
)

$state = [ordered]@{
    protocol_version = 3
    task_id = $taskId
    worker_name = $Worker
    state = 'DISPATCHED'
    updated_at = $created
    last_command = $null
    pid = $null
    cell_id = $null
    exit_code = $null
    changed_files = @()
    elapsed_seconds = 0
}
[IO.File]::WriteAllText(
    $statePath,
    ($state | ConvertTo-Json -Depth 5) + "`r`n",
    [Text.UTF8Encoding]::new($false)
)

Write-Output "TASK_ID=$taskId"
Write-Output "TASK_PATH=$taskPath"
Write-Output "TASK_SHA256=$taskHash"
Write-Output "BINDING_PATH=$bindingPath"
Write-Output "STATE_PATH=$statePath"
Write-Output "WORKER=$Worker"
Write-Output "EXPECTED_MINUTES=$ExpectedMinutes"
Write-Output "FIRST_OBSERVATION_SECONDS=$FirstObservationSeconds"
Write-Output 'SPAWN_MESSAGE_BEGIN'
Write-Output "Use custom agent $Worker with fork_turns=none."
Write-Output "Task ID: $taskId"
Write-Output "Canonical root: $ProjectRoot"
Write-Output "Task path: $taskPath"
Write-Output "Binding path: $bindingPath"
Write-Output "Task SHA-256: $taskHash"
Write-Output "Expected minutes: $ExpectedMinutes; first observation: $FirstObservationSeconds seconds."
Write-Output 'Read task and binding together in the first tool call. All binding fields are present: do not read the descriptor or scan task directories. Begin work without a separate plan or acknowledgement.'
Write-Output 'SPAWN_MESSAGE_END'
