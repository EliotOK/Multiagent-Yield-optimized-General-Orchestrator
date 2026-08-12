[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^rmo-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$')]
    [string]$TaskId,
    [ValidateSet('REVIEWED', 'FAILED', 'BLOCKED', 'INTERRUPTED')]
    [string]$Outcome = 'REVIEWED',
    [switch]$ConfirmWorkerStopped,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$lifecycleLock = $null
$stateLock = $null
trap {
    if ($null -ne $stateLock) { $stateLock.Dispose() }
    if ($null -ne $lifecycleLock) { $lifecycleLock.Dispose() }
    throw $_
}
function Release-Locks {
    if ($null -ne $script:stateLock) { $script:stateLock.Dispose(); $script:stateLock = $null }
    if ($null -ne $script:lifecycleLock) { $script:lifecycleLock.Dispose(); $script:lifecycleLock = $null }
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$taskPath = Join-Path $ProjectRoot ".codex\tasks\$TaskId.md"
$bindingPath = Join-Path $ProjectRoot ".codex\bindings\$TaskId.json"
$statePath = Join-Path $ProjectRoot "work\worker_state\$TaskId.json"
$archiveRoot = Join-Path $ProjectRoot ".codex\diagnostics\task-history\$TaskId"
$archiveParent = Split-Path -Parent $archiveRoot
$stagingRoot = Join-Path $archiveParent (".$TaskId.staging-" + [guid]::NewGuid().ToString('N'))
$lifecycleLockPath = Join-Path $ProjectRoot '.codex\bindings\.create.lock'
$stateLockPath = Join-Path $ProjectRoot "work\worker_state\$TaskId.state.lock"

function Assert-DescendantSafe([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project root: $resolved"
    }
    $rootItem = Get-Item -LiteralPath $ProjectRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse point as project root: $ProjectRoot"
    }
    $cursor = $resolved
    while (-not $cursor.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to archive through a reparse point: $cursor"
            }
        }
        $cursor = (Split-Path -Parent $cursor).TrimEnd('\')
    }
}

Assert-DescendantSafe $archiveRoot
foreach ($lockPath in @($lifecycleLockPath, $stateLockPath)) {
    Assert-DescendantSafe $lockPath
    if (Test-Path -LiteralPath $lockPath) {
        $lockItem = Get-Item -LiteralPath $lockPath -Force
        if (($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Coordination lock must not be a reparse point: $lockPath"
        }
    }
}
try {
    $lifecycleLock = [IO.File]::Open($lifecycleLockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stateLock = [IO.File]::Open($stateLockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch { throw 'Task lifecycle or state update is still active; refusing to close.' }

if (Test-Path -LiteralPath $archiveRoot -PathType Container) {
    $archivedTask = Join-Path $archiveRoot 'task.md'
    $archivedBinding = Join-Path $archiveRoot 'binding.json'
    $archivedState = Join-Path $archiveRoot 'state.json'
    foreach ($path in @($archivedTask, $archivedBinding, $archivedState)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Existing archive is incomplete and requires manual recovery: $archiveRoot"
        }
    }
    $archivedHash = (Get-FileHash -LiteralPath $archivedTask -Algorithm SHA256).Hash.ToLowerInvariant()
    $archivedBindingObject = Get-Content -LiteralPath $archivedBinding -Raw | ConvertFrom-Json
    $archivedStateObject = Get-Content -LiteralPath $archivedState -Raw | ConvertFrom-Json
    if ($archivedHash -ne [string]$archivedBindingObject.task_sha256 -or
        $archivedBindingObject.task_id -ne $TaskId -or
        $archivedBindingObject.protocol_version -ne 3 -or
        $archivedStateObject.protocol_version -ne 3 -or
        $archivedStateObject.task_id -ne $TaskId -or
        $archivedStateObject.worker_name -ne $archivedBindingObject.worker_name -or
        $archivedStateObject.state -ne $archivedBindingObject.status) {
        throw "Existing archive is invalid: $archiveRoot"
    }
    Write-Output "TASK_ID=$TaskId"
    Write-Output "OUTCOME=$($archivedBindingObject.status)"
    Write-Output "ARCHIVE_PATH=$archiveRoot"
    if (-not $Apply) {
        Write-Output 'MODE=RECOVERY_DRY_RUN'
        Write-Output 'A valid archive already exists. Apply with worker-stop confirmation to clear any matching active remnants.'
        Release-Locks
        exit 0
    }
    if (-not $ConfirmWorkerStopped) { throw 'Recovery cleanup requires -ConfirmWorkerStopped.' }
    if (Test-Path -LiteralPath $taskPath -PathType Leaf) {
        $activeTaskHash = (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($activeTaskHash -ne $archivedHash) {
            throw 'Active task remnant differs from the archive; refusing automatic recovery cleanup.'
        }
    }
    if (Test-Path -LiteralPath $bindingPath -PathType Leaf) {
        $activeBinding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
        if ($activeBinding.task_id -ne $TaskId -or
            [string]$activeBinding.task_sha256 -ne $archivedHash) {
            throw 'Active binding remnant differs from the archive; refusing automatic recovery cleanup.'
        }
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $activeState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($activeState.task_id -ne $TaskId -or
            $activeState.worker_name -ne $archivedBindingObject.worker_name) {
            throw 'Active state remnant differs from the archive; refusing automatic recovery cleanup.'
        }
    }
    foreach ($activePath in @($taskPath, $bindingPath, $statePath)) {
        if (Test-Path -LiteralPath $activePath -PathType Leaf) {
            Remove-Item -LiteralPath $activePath -Force
        }
    }
    Write-Output 'CLOSE_TASK_RESULT=PASS'
    Write-Output 'Recovered from a previously published valid archive and cleared active remnants.'
    Release-Locks
    exit 0
}

foreach ($path in @($taskPath, $bindingPath, $statePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Coordination artifact is missing: $path"
    }
    Assert-DescendantSafe $path
}

$binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
if ($binding.task_id -ne $TaskId) { throw 'Binding task ID mismatch.' }
if ([IO.Path]::GetFullPath($binding.canonical_root).TrimEnd('\') -ne $ProjectRoot) {
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
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.task_id -ne $TaskId) { throw 'State task ID mismatch.' }
if ($state.worker_name -ne $binding.worker_name) { throw 'State worker mismatch.' }
$requiredState = if ($Outcome -eq 'REVIEWED') { 'AGENT_COMPLETED' } else { $Outcome }
if ($state.state -ne $requiredState) {
    throw "$Outcome requires $requiredState state; current state is $($state.state)."
}

Write-Output "TASK_ID=$TaskId"
Write-Output "OUTCOME=$Outcome"
Write-Output "ARCHIVE_PATH=$archiveRoot"
if (-not $Apply) {
    Write-Output 'MODE=DRY_RUN'
    Write-Output 'No files were changed. Confirm agent, tool cell, PID, and child processes are stopped.'
    Write-Output 'Rerun with -ConfirmWorkerStopped -Apply to archive coordination evidence.'
    Release-Locks
    exit 0
}
if (-not $ConfirmWorkerStopped) {
    throw 'Refusing to close an active task without -ConfirmWorkerStopped.'
}

$taskText = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8
if ($taskText -notmatch '(?m)^Status:\s*READY\s*$') { throw 'Task status is not READY.' }

$binding.status = $Outcome
$binding | Add-Member -NotePropertyName closed_at -NotePropertyValue (Get-Date).ToString('o') -Force
$state.state = $Outcome
$state.updated_at = (Get-Date).ToString('o')

try {
    New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $stagingRoot 'task.md'), $taskText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $stagingRoot 'binding.json'), ($binding | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $stagingRoot 'state.json'), ($state | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $stagingRoot -Destination $archiveRoot
}
catch {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    throw
}

foreach ($activePath in @($taskPath, $bindingPath, $statePath)) {
    Remove-Item -LiteralPath $activePath -Force
}

Write-Output 'CLOSE_TASK_RESULT=PASS'
Write-Output 'Immutable evidence was archived and the matching active coordination artifacts were cleared.'
Release-Locks
