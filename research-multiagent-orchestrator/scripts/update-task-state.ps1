[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^rmo-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$')]
    [string]$TaskId,
    [Parameter(Mandatory = $true)]
    [ValidateSet('AGENT_CREATED', 'TASK_ACKNOWLEDGED', 'TOOL_STARTED', 'RUNNING',
        'OUTPUT_READY', 'AGENT_COMPLETED', 'FAILED', 'BLOCKED', 'INTERRUPTED')]
    [string]$NewState,
    [string]$LastCommand = '',
    [int]$ProcessId = 0,
    [string]$CellId = '',
    [Nullable[int]]$ExitCode = $null,
    [string[]]$ChangedFiles = @()
)

$ErrorActionPreference = 'Stop'
$lockStream = $null
trap {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
    throw $_
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$rootPrefix = $ProjectRoot + '\'
$rootItem = Get-Item -LiteralPath $ProjectRoot -Force
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'ProjectRoot must not be a reparse point.'
}
$statePath = Join-Path $ProjectRoot "work\worker_state\$TaskId.json"
$bindingPath = Join-Path $ProjectRoot ".codex\bindings\$TaskId.json"
$taskPath = Join-Path $ProjectRoot ".codex\tasks\$TaskId.md"
foreach ($dir in @((Split-Path -Parent $statePath), (Split-Path -Parent $bindingPath))) {
    $item = Get-Item -LiteralPath $dir -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Coordination directory must not be a reparse point: $dir"
    }
}
foreach ($path in @($statePath, $bindingPath, $taskPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Coordination artifact is missing: $path"
    }
}

$lockPath = Join-Path (Split-Path -Parent $statePath) "$TaskId.state.lock"
try {
    if (Test-Path -LiteralPath $lockPath) {
        $lockItem = Get-Item -LiteralPath $lockPath -Force
        if (($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'State lock must not be a reparse point.'
        }
    }
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch { throw 'Another state update is already in progress for this task.' }

$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($binding.task_id -ne $TaskId -or $state.task_id -ne $TaskId) { throw 'Task ID mismatch.' }
if ($binding.worker_name -ne $state.worker_name) { throw 'Worker identity mismatch.' }
if ($binding.protocol_version -ne 4 -or $state.protocol_version -ne 4) { throw 'Protocol version mismatch.' }
if ($binding.status -ne 'READY') { throw "Binding is not READY: $($binding.status)" }
if ([IO.Path]::GetFullPath([string]$binding.canonical_root).TrimEnd('\') -ne $ProjectRoot) {
    throw 'Binding canonical root mismatch.'
}
if ([IO.Path]::GetFullPath([string]$binding.task_path) -ne [IO.Path]::GetFullPath($taskPath)) {
    throw 'Binding task path mismatch.'
}
if ([IO.Path]::GetFullPath([string]$binding.state_path) -ne [IO.Path]::GetFullPath($statePath)) {
    throw 'Binding state path mismatch.'
}
$taskHash = (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($taskHash -ne [string]$binding.task_sha256) { throw 'Task hash mismatch.' }

$allowed = @{
    DISPATCHED = @('AGENT_CREATED', 'FAILED', 'BLOCKED', 'INTERRUPTED')
    AGENT_CREATED = @('TASK_ACKNOWLEDGED', 'TOOL_STARTED', 'RUNNING', 'FAILED', 'BLOCKED', 'INTERRUPTED')
    TASK_ACKNOWLEDGED = @('TOOL_STARTED', 'RUNNING', 'FAILED', 'BLOCKED', 'INTERRUPTED')
    TOOL_STARTED = @('RUNNING', 'OUTPUT_READY', 'FAILED', 'BLOCKED', 'INTERRUPTED')
    RUNNING = @('RUNNING', 'OUTPUT_READY', 'FAILED', 'BLOCKED', 'INTERRUPTED')
    OUTPUT_READY = @('AGENT_COMPLETED', 'FAILED', 'BLOCKED', 'INTERRUPTED')
    AGENT_COMPLETED = @()
    FAILED = @()
    BLOCKED = @()
    INTERRUPTED = @()
}
$current = [string]$state.state
if (-not $allowed.ContainsKey($current) -or $NewState -notin $allowed[$current]) {
    throw "Illegal task-state transition: $current -> $NewState"
}

foreach ($file in $ChangedFiles) {
    if ($file -match '[\r\n]') { throw 'ChangedFiles entries must not contain newlines.' }
    $full = if ([IO.Path]::IsPathRooted($file)) { [IO.Path]::GetFullPath($file) }
        else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $file)) }
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Changed file is outside the project root: $file"
    }
}

$state.state = $NewState
$state.updated_at = (Get-Date).ToString('o')
if (-not [string]::IsNullOrWhiteSpace($LastCommand)) { $state.last_command = $LastCommand }
if ($ProcessId -gt 0) { $state.pid = $ProcessId }
if (-not [string]::IsNullOrWhiteSpace($CellId)) { $state.cell_id = $CellId }
if ($null -ne $ExitCode) { $state.exit_code = $ExitCode }
if ($ChangedFiles.Count -gt 0) { $state.changed_files = @($ChangedFiles) }
$createdAt = [DateTimeOffset]::Parse([string]$state.updated_at)
$dispatchAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$binding.dispatch_epoch_ms)
$state.elapsed_seconds = [math]::Max(0, [math]::Round(($createdAt - $dispatchAt).TotalSeconds, 3))

$tempPath = $statePath + '.tmp-' + [guid]::NewGuid().ToString('N')
$replaceBackup = $statePath + '.replace-backup-' + [guid]::NewGuid().ToString('N')
try {
    [IO.File]::WriteAllText($tempPath, ($state | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($tempPath, $statePath, $replaceBackup, $true)
}
finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force }
}
$lockStream.Dispose()
$lockStream = $null
Write-Output "TASK_STATE=$NewState"
