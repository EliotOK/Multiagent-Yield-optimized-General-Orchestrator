[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('deepseek_context_worker', 'deepseek_context_reasoning_worker',
        'deepseek_batch_worker', 'luna_medium_worker', 'luna_high_worker',
        'luna_max_worker', 'terra_readonly_fallback_worker', 'terra_fallback_worker',
        'astra_review_worker', 'sol_review_worker')]
    [string]$Worker,
    [Parameter(Mandatory = $true)]
    [string]$Objective,
    [string]$TaskLabel = '',
    [string[]]$AllowedFiles = @(),
    [string[]]$ForbiddenActions = @(
        'Modify raw data', 'Commit or push', 'Change scientific assumptions',
        'Install system-wide dependencies', 'Modify task or binding files'
    ),
    [string[]]$ValidationCommands = @(),
    [ValidateSet('AUTO', 'READ_ONLY', 'WORKSPACE_WRITE')]
    [string]$Mode = 'AUTO',
    [ValidateSet('LOCAL_ONLY', 'APPROVED_EXTERNAL', 'PUBLIC')]
    [string]$DataSensitivity = 'LOCAL_ONLY',
    [ValidateSet('AUTO', 'CURRENT', 'ASTRA', 'SOL')]
    [string]$PrimaryProfile = 'AUTO',
    [string]$ObservedPrimaryModel = '',
    [string]$ObservedPrimaryEffort = '',
    [int]$ExpectedMinutes = 0,
    [int]$FirstObservationSeconds = 30,
    [string]$PreviousFailureTaskId = ''
)

$ErrorActionPreference = 'Stop'
$lockStream = $null
trap {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
    throw $_
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "ProjectRoot does not exist: $ProjectRoot"
}
$rootItem = Get-Item -LiteralPath $ProjectRoot -Force
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'ProjectRoot must not be a reparse point.'
}

$descriptor = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
if (-not (Test-Path -LiteralPath $descriptor)) {
    throw "Workflow is not installed in this project: $descriptor"
}
$descriptorText = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8
$rootForToml = $ProjectRoot.Replace('\', '/')
if ($descriptorText -notmatch ('(?m)^canonical_root\s*=\s*"' + [regex]::Escape($rootForToml) + '"\s*$')) {
    throw 'Workflow descriptor canonical root mismatch.'
}
if ($descriptorText -notmatch '(?m)^protocol_version\s*=\s*4\s*$') {
    throw 'Workflow descriptor protocol version is missing or unsupported.'
}
if ($descriptorText -notmatch '(?m)^primary_profile_mode\s*=\s*"current-session"\s*$') {
    throw 'Workflow descriptor does not support current-session primary resolution. Reinstall MYGO.'
}
if ($descriptorText -notmatch '(?m)^model_map_schema\s*=\s*1\s*$') {
    throw 'Workflow descriptor has an unsupported model-map schema. Reinstall MYGO.'
}
if ($descriptorText -notmatch '(?m)^deepseek_enabled\s*=\s*(true|false)\s*$') {
    throw 'Workflow descriptor does not declare deepseek_enabled.'
}
$modelMapPath = Join-Path $ProjectRoot '.codex\mygo-model-map.json'
if (-not (Test-Path -LiteralPath $modelMapPath -PathType Leaf)) {
    throw "MYGO model map is missing: $modelMapPath"
}
$modelMap = Get-Content -LiteralPath $modelMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($modelMap.schema_version -ne 1) { throw 'Unsupported MYGO model-map schema.' }
if ([string]$modelMap.default_primary -ne 'CURRENT') {
    throw 'MYGO requires default_primary=CURRENT. Reinstall or migrate the project workflow.'
}
$workerProperty = $modelMap.agents.psobject.Properties[$Worker]
if ($null -eq $workerProperty) { throw "Worker is absent from the MYGO model map: $Worker" }
$workerSpec = $workerProperty.Value
$workerProvider = [string]$workerSpec.provider
$workerCodename = [string]$workerSpec.codename
if ($workerProvider -notin @('default', 'deepseek')) {
    throw "Unsupported provider in MYGO model map for ${Worker}: $workerProvider"
}
if ($workerCodename -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') {
    throw "Invalid worker codename in MYGO model map for ${Worker}: $workerCodename"
}
if ($workerProvider -eq 'deepseek' -and
    $descriptorText -match '(?m)^deepseek_enabled\s*=\s*false\s*$') {
    throw "DeepSeek routing is disabled for this project. Reinstall explicitly without -LunaOnly before creating $Worker tasks."
}
if ($workerProvider -eq 'deepseek' -and $DataSensitivity -eq 'LOCAL_ONLY') {
    throw 'DeepSeek routes transmit selected context to an external provider. Set DataSensitivity to APPROVED_EXTERNAL or PUBLIC only after confirming the data may be sent.'
}
$resolverPath = Join-Path $PSScriptRoot 'resolve-primary-profile.ps1'
if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
    throw "Primary-profile resolver is missing: $resolverPath"
}
$resolverArgs = @{ ProjectRoot = $ProjectRoot }
if (-not [string]::IsNullOrWhiteSpace($ObservedPrimaryModel)) {
    $resolverArgs.ObservedModel = $ObservedPrimaryModel
}
if (-not [string]::IsNullOrWhiteSpace($ObservedPrimaryEffort)) {
    $resolverArgs.ObservedEffort = $ObservedPrimaryEffort
}
$resolutionOutput = @(& $resolverPath @resolverArgs)
$resolution = @{}
foreach ($line in $resolutionOutput) {
    if ($line -match '^([A-Z_]+)=(.*)$') { $resolution[$matches[1]] = $matches[2] }
}
$resolvedPrimaryProfile = [string]$resolution.PRIMARY_PROFILE
if ($resolvedPrimaryProfile -notin @('CURRENT', 'ASTRA', 'SOL')) {
    throw 'Primary-profile resolver returned no supported current-session profile.'
}
if ($PrimaryProfile -ne 'AUTO' -and $PrimaryProfile -ne $resolvedPrimaryProfile) {
    throw "Requested PrimaryProfile $PrimaryProfile does not match current-session profile $resolvedPrimaryProfile."
}
$PrimaryProfile = $resolvedPrimaryProfile
$primaryModel = [string]$resolution.PRIMARY_MODEL
$primaryEffort = [string]$resolution.PRIMARY_REASONING_EFFORT
$primaryResolutionSource = [string]$resolution.PROFILE_RESOLUTION_SOURCE

if ($Worker -eq 'astra_review_worker' -and $PrimaryProfile -ne 'SOL') {
    throw 'astra_review_worker is advisory only and requires PrimaryProfile SOL.'
}
if ($Worker -eq 'sol_review_worker' -and $PrimaryProfile -ne 'ASTRA') {
    throw 'sol_review_worker is advisory only and requires PrimaryProfile ASTRA.'
}

$taskDir = Join-Path $ProjectRoot '.codex\tasks'
$bindingDir = Join-Path $ProjectRoot '.codex\bindings'
$stateDir = Join-Path $ProjectRoot 'work\worker_state'
foreach ($dir in @($taskDir, $bindingDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Required directory is missing: $dir"
    }
    $item = Get-Item -LiteralPath $dir -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Coordination directory must not be a reparse point: $dir"
    }
}

$lockPath = Join-Path $bindingDir '.create.lock'
try {
    if (Test-Path -LiteralPath $lockPath) {
        $lockItem = Get-Item -LiteralPath $lockPath -Force
        if (($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Task creation lock must not be a reparse point.'
        }
    }
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch {
    throw 'Another task creation is already in progress for this project.'
}

$activeBindings = @(Get-ChildItem -LiteralPath $bindingDir -Filter 'rmo-*.json' -File)
if ($activeBindings.Count -gt 0) {
    throw "An active or unreadable binding already exists. Finish it before creating another: $($activeBindings.FullName -join ', ')"
}
$orphanTasks = @(Get-ChildItem -LiteralPath $taskDir -Filter 'rmo-*.md' -File)
$orphanStates = @(Get-ChildItem -LiteralPath $stateDir -Filter 'rmo-*.json' -File)
if ($orphanTasks.Count -gt 0 -or $orphanStates.Count -gt 0) {
    $orphans = @($orphanTasks.FullName) + @($orphanStates.FullName)
    throw "Orphan coordination artifacts exist without a binding; recover or archive them before creating another task: $($orphans -join ', ')"
}

if ($Mode -eq 'AUTO') {
    $Mode = if ($Worker -like 'deepseek_context_*' -or
        $Worker -eq 'terra_readonly_fallback_worker' -or
        $Worker -in @('astra_review_worker', 'sol_review_worker')) { 'READ_ONLY' } else { 'WORKSPACE_WRITE' }
}
if ($Worker -like 'deepseek_context_*' -and $Mode -ne 'READ_ONLY') {
    throw "$Worker requires READ_ONLY mode."
}
if ($Worker -in @('deepseek_batch_worker', 'luna_medium_worker',
        'luna_high_worker', 'luna_max_worker') -and $Mode -ne 'WORKSPACE_WRITE') {
    throw "$Worker requires WORKSPACE_WRITE mode."
}
if ($Worker -eq 'terra_readonly_fallback_worker' -and $Mode -ne 'READ_ONLY') {
    throw 'terra_readonly_fallback_worker requires READ_ONLY mode.'
}
if ($Worker -eq 'terra_fallback_worker' -and $Mode -ne 'WORKSPACE_WRITE') {
    throw 'terra_fallback_worker is the write-capable fallback; use terra_readonly_fallback_worker for read-only recovery.'
}
if ($Worker -in @('astra_review_worker', 'sol_review_worker') -and $Mode -ne 'READ_ONLY') {
    throw "$Worker requires READ_ONLY mode."
}
$hardForbidden = @('Modify raw data', 'Commit or push', 'Change scientific assumptions',
    'Install system-wide dependencies', 'Modify task or binding files')
$ForbiddenActions = @($hardForbidden + $ForbiddenActions | Select-Object -Unique)
foreach ($field in @($AllowedFiles + $ForbiddenActions + $ValidationCommands)) {
    if ($field -match '[\r\n]') { throw 'List fields must not contain newline characters.' }
}
if ($TaskLabel -match '[\r\n]') {
    throw 'TaskLabel must be a concise single-line description.'
}
if ($Mode -eq 'WORKSPACE_WRITE') {
    if ($AllowedFiles.Count -eq 0) { throw 'Write-capable tasks require at least one AllowedFiles entry.' }
    if ($ValidationCommands.Count -eq 0) { throw 'Write-capable tasks require at least one validation command.' }
}
foreach ($allowedFile in $AllowedFiles) {
    if ($allowedFile -match '[*?]') { throw 'AllowedFiles entries must be explicit paths, not wildcards.' }
    $allowedPath = if ([IO.Path]::IsPathRooted($allowedFile)) {
        [IO.Path]::GetFullPath($allowedFile)
    } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $allowedFile)) }
    if (-not $allowedPath.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Allowed file is outside the project root: $allowedFile"
    }
    $cursor = $allowedPath
    while (-not $cursor.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Allowed file resolves through a reparse point: $allowedFile"
            }
        }
        $cursor = (Split-Path -Parent $cursor).TrimEnd('\')
    }
}
if (-not [string]::IsNullOrWhiteSpace($PreviousFailureTaskId) -and
    $PreviousFailureTaskId -notmatch '^rmo-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$') {
    throw 'PreviousFailureTaskId has an invalid format.'
}
if ($Worker -in @('terra_readonly_fallback_worker', 'terra_fallback_worker')) {
    if ($PreviousFailureTaskId -notmatch '^rmo-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$') {
        throw 'Terra fallback requires a valid PreviousFailureTaskId.'
    }
    $previousArchive = Join-Path $ProjectRoot ".codex\diagnostics\task-history\$PreviousFailureTaskId"
    foreach ($name in @('task.md', 'binding.json', 'state.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $previousArchive $name) -PathType Leaf)) {
            throw "Terra fallback evidence is incomplete: $previousArchive"
        }
    }
    $previousBinding = Get-Content -LiteralPath (Join-Path $previousArchive 'binding.json') -Raw | ConvertFrom-Json
    if ($previousBinding.status -notin @('FAILED', 'BLOCKED', 'INTERRUPTED')) {
        throw 'Terra fallback requires archived FAILED, BLOCKED, or INTERRUPTED evidence.'
    }
}

if ($ExpectedMinutes -le 0) {
    $ExpectedMinutes = switch ($Worker) {
        'deepseek_context_worker' { 5 }
        'deepseek_context_reasoning_worker' { 12 }
        'deepseek_batch_worker' { 6 }
        'luna_medium_worker' { 5 }
        'luna_high_worker' { 7 }
        'luna_max_worker' { 8 }
        'astra_review_worker' { 3 }
        'sol_review_worker' { 4 }
        default { 8 }
    }
}
if ($FirstObservationSeconds -lt 10) {
    throw 'FirstObservationSeconds must be at least 10.'
}

function ConvertTo-TaskSlug([string]$Text, [int]$MaximumLength) {
    $slug = [regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'TaskLabel must contain an ASCII letter or number because Codex child task_name accepts only lowercase letters, numbers, and underscores.'
    }
    if ($slug.Length -gt $MaximumLength) {
        $slug = $slug.Substring(0, $MaximumLength).TrimEnd('_')
    }
    return $slug
}

$taskLabel = if ([string]::IsNullOrWhiteSpace($TaskLabel)) {
    (($Objective -split "\r?\n", 2)[0]).Trim()
} else { $TaskLabel.Trim() }
if ($taskLabel.Length -gt 80) {
    $taskLabel = $taskLabel.Substring(0, 80).TrimEnd()
}
$taskNamePrefix = $workerCodename.ToLowerInvariant()
$taskSlug = ConvertTo-TaskSlug $taskLabel ([math]::Max(8, 63 - $taskNamePrefix.Length))
$spawnTaskName = $taskNamePrefix + '_' + $taskSlug
$taskDisplayName = $workerCodename + ' — ' + $taskLabel

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$taskId = "rmo-$stamp-$suffix"
$taskPath = Join-Path $taskDir "$taskId.md"
$bindingPath = Join-Path $bindingDir "$taskId.json"
$statePath = Join-Path $stateDir "$taskId.json"
$mode = $Mode

function Format-List([string[]]$Items, [string]$EmptyText) {
    if ($Items.Count -eq 0) { return "- $EmptyText" }
    return ($Items | ForEach-Object { "- $_" }) -join "`r`n"
}

$allowed = Format-List $AllowedFiles 'No writes allowed unless an explicit path is listed.'
$forbidden = Format-List $ForbiddenActions 'No additional forbidden actions.'
$validation = Format-List $ValidationCommands 'Return a read-only evidence report; no execution validation specified.'
$previous = if ([string]::IsNullOrWhiteSpace($PreviousFailureTaskId)) { 'None' } else { $PreviousFailureTaskId }
$created = (Get-Date).ToString('o')

$objectiveQuoted = (($Objective -split "\r?\n") | ForEach-Object { "> $_" }) -join "`r`n"
$stateUpdater = Join-Path $PSScriptRoot 'update-task-state.ps1'
$taskText = @"
Task ID: $taskId
Status: READY
Worker: $Worker
Worker codename: $workerCodename
Task label: $taskLabel
Mode: $mode
Data sensitivity: $DataSensitivity
Primary profile: $PrimaryProfile
Primary model: $primaryModel
Primary reasoning effort: $primaryEffort
Primary resolution source: $primaryResolutionSource
Canonical root: $ProjectRoot
Created: $created
Previous failure task: $previous
Expected duration minutes: $ExpectedMinutes
First observation seconds: $FirstObservationSeconds

## Objective

$objectiveQuoted

## Allowed files

$allowed

## Coordination reads

- The exact task and binding paths supplied in the spawn message.
- `.codex/research-multiagent.toml` only if a required binding field is missing.

## Coordination writes

- Update state only through `$stateUpdater`; never edit the JSON directly.
- Never modify the task or binding files.

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

try {
    $taskTemp = $taskPath + '.rmo-tmp'
    $bindingTemp = $bindingPath + '.rmo-tmp'
    $stateTemp = $statePath + '.rmo-tmp'
    [IO.File]::WriteAllText($taskTemp, $taskText.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))
    $taskHash = (Get-FileHash -LiteralPath $taskTemp -Algorithm SHA256).Hash.ToLowerInvariant()

$binding = [ordered]@{
    protocol_version = 4
    task_id = $taskId
    status = 'READY'
    worker_name = $Worker
    worker_codename = $workerCodename
    task_label = $taskLabel
    task_name = $spawnTaskName
    mode = $mode
    primary_profile = $PrimaryProfile
    primary_model = $primaryModel
    primary_reasoning_effort = $primaryEffort
    primary_resolution_source = $primaryResolutionSource
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
        $bindingTemp,
        ($binding | ConvertTo-Json -Depth 5) + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )

$state = [ordered]@{
    protocol_version = 4
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
        $stateTemp,
        ($state | ConvertTo-Json -Depth 5) + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::Move($taskTemp, $taskPath)
    [IO.File]::Move($stateTemp, $statePath)
    # Publish the binding last. A hard stop can leave detectable task/state orphans,
    # but never a READY binding that points to missing task/state files.
    [IO.File]::Move($bindingTemp, $bindingPath)
}
catch {
    foreach ($createdPath in @($stateTemp, $bindingTemp, $taskTemp,
            $statePath, $bindingPath, $taskPath)) {
        if (Test-Path -LiteralPath $createdPath -PathType Leaf) {
            Remove-Item -LiteralPath $createdPath -Force
        }
    }
    throw
}

$lockStream.Dispose()
$lockStream = $null

Write-Output "TASK_ID=$taskId"
Write-Output "TASK_PATH=$taskPath"
Write-Output "TASK_SHA256=$taskHash"
Write-Output "BINDING_PATH=$bindingPath"
Write-Output "STATE_PATH=$statePath"
Write-Output "WORKER=$Worker"
Write-Output "WORKER_CODENAME=$workerCodename"
Write-Output "TASK_DISPLAY_NAME=$taskDisplayName"
Write-Output "SPAWN_TASK_NAME=$spawnTaskName"
Write-Output "PRIMARY_PROFILE=$PrimaryProfile"
Write-Output "PRIMARY_MODEL=$primaryModel"
Write-Output "PRIMARY_REASONING_EFFORT=$primaryEffort"
Write-Output "PRIMARY_RESOLUTION_SOURCE=$primaryResolutionSource"
Write-Output "EXPECTED_MINUTES=$ExpectedMinutes"
Write-Output "FIRST_OBSERVATION_SECONDS=$FirstObservationSeconds"
Write-Output 'SPAWN_MESSAGE_BEGIN'
Write-Output "Use custom agent $Worker with fork_turns=none and task_name=$spawnTaskName."
Write-Output "Task ID: $taskId"
Write-Output "Canonical root: $ProjectRoot"
Write-Output "Task path: $taskPath"
Write-Output "Binding path: $bindingPath"
Write-Output "Task SHA-256: $taskHash"
Write-Output "Primary profile: $PrimaryProfile"
Write-Output "Primary model: $primaryModel"
Write-Output "Primary reasoning effort: $primaryEffort"
Write-Output "Primary resolution source: $primaryResolutionSource"
Write-Output "Worker codename: $workerCodename"
Write-Output "Expected minutes: $ExpectedMinutes; first observation: $FirstObservationSeconds seconds."
Write-Output 'Read task and binding together in the first tool call. All binding fields are present: do not read the descriptor or scan task directories. Begin work without a separate plan or acknowledgement.'
Write-Output 'SPAWN_MESSAGE_END'
