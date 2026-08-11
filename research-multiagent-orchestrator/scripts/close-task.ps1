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
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$taskPath = Join-Path $ProjectRoot ".codex\tasks\$TaskId.md"
$bindingPath = Join-Path $ProjectRoot ".codex\bindings\$TaskId.json"
$statePath = Join-Path $ProjectRoot "work\worker_state\$TaskId.json"
$archiveRoot = Join-Path $ProjectRoot ".codex\diagnostics\task-history\$TaskId"

foreach ($path in @($taskPath, $bindingPath, $statePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Coordination artifact is missing: $path"
    }
    $resolved = [IO.Path]::GetFullPath($path)
    if (-not $resolved.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Artifact is outside the project root: $resolved"
    }
}

$binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
if ($binding.task_id -ne $TaskId) { throw 'Binding task ID mismatch.' }
if ([IO.Path]::GetFullPath($binding.canonical_root).TrimEnd('\') -ne $ProjectRoot) {
    throw 'Binding canonical root mismatch.'
}

Write-Output "TASK_ID=$TaskId"
Write-Output "OUTCOME=$Outcome"
Write-Output "ARCHIVE_PATH=$archiveRoot"
if (-not $Apply) {
    Write-Output 'MODE=DRY_RUN'
    Write-Output 'No files were changed. Confirm agent, tool cell, PID, and child processes are stopped.'
    Write-Output 'Rerun with -ConfirmWorkerStopped -Apply to archive coordination evidence.'
    exit 0
}
if (-not $ConfirmWorkerStopped) {
    throw 'Refusing to close an active task without -ConfirmWorkerStopped.'
}

$taskText = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8
$taskText = [regex]::Replace($taskText, '(?m)^Status:\s*READY\s*$', "Status: $Outcome", 1)
[IO.File]::WriteAllText($taskPath, $taskText, [Text.UTF8Encoding]::new($false))

$binding.status = $Outcome
$binding | Add-Member -NotePropertyName closed_at -NotePropertyValue (Get-Date).ToString('o') -Force
[IO.File]::WriteAllText($bindingPath, ($binding | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$state.state = $Outcome
$state.updated_at = (Get-Date).ToString('o')
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))

New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
Move-Item -LiteralPath $taskPath -Destination (Join-Path $archiveRoot 'task.md')
Move-Item -LiteralPath $bindingPath -Destination (Join-Path $archiveRoot 'binding.json')
Move-Item -LiteralPath $statePath -Destination (Join-Path $archiveRoot 'state.json')

Write-Output 'CLOSE_TASK_RESULT=PASS'
Write-Output 'The evidence was archived; no coordination artifact was deleted.'
