[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [ValidatePattern('^$|^rmo-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$')]
    [string]$TaskId = '',
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
    $script:checks.Add([pscustomobject]@{
        Check = $Name; Status = $(if ($Passed) { 'PASS' } else { 'FAIL' }); Detail = $Detail
    })
}
function Add-Warning([string]$Name, [string]$Detail) {
    $script:checks.Add([pscustomobject]@{
        Check = $Name; Status = 'WARN'; Detail = $Detail
    })
}

Add-Check 'canonical_root_exists' (Test-Path -LiteralPath $ProjectRoot -PathType Container) $ProjectRoot
if (Test-Path -LiteralPath $ProjectRoot) {
    $rootItem = Get-Item -LiteralPath $ProjectRoot -Force
    Add-Check 'canonical_root_not_reparse' `
        (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) $ProjectRoot
}
$descriptor = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
Add-Check 'descriptor' (Test-Path -LiteralPath $descriptor -PathType Leaf) $descriptor
if (Test-Path -LiteralPath $descriptor) {
    $descriptorText = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8
    $rootToml = $ProjectRoot.Replace('\', '/')
    Add-Check 'descriptor_root_matches' ($descriptorText -match ('canonical_root\s*=\s*"' + [regex]::Escape($rootToml) + '"')) $rootToml
    Add-Check 'descriptor_protocol' ($descriptorText -match '(?m)^protocol_version\s*=\s*3\s*$') 'protocol_version=3'
    Add-Check 'descriptor_primary_profile_mode' `
        ($descriptorText -match '(?m)^primary_profile_mode\s*=\s*"session-choice"\s*$') `
        'primary_profile_mode=session-choice'
    Add-Check 'descriptor_model_map_schema' `
        ($descriptorText -match '(?m)^model_map_schema\s*=\s*1\s*$') `
        'model_map_schema=1'
}

$bindingDir = Join-Path $ProjectRoot '.codex\bindings'
if (Test-Path -LiteralPath $bindingDir -PathType Container) {
    $bindingDirItem = Get-Item -LiteralPath $bindingDir -Force
    Add-Check 'binding_directory_not_reparse' `
        (($bindingDirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) $bindingDir
}
$bindings = if (Test-Path -LiteralPath $bindingDir -PathType Container) {
    @(Get-ChildItem -LiteralPath $bindingDir -Filter '*.json' -File)
} else { @() }
$unreadableBindings = @($bindings | Where-Object {
    try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null; $false }
    catch { $true }
})
Add-Check 'binding_files_readable' ($unreadableBindings.Count -eq 0) "unreadable=$($unreadableBindings.Count)"
$ready = @($bindings | Where-Object {
    try { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).status -eq 'READY' }
    catch { $false }
})
Add-Check 'ready_binding_count' ($ready.Count -le 1) "count=$($ready.Count)"

if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
    $bindingPath = Join-Path $bindingDir "$TaskId.json"
    Add-Check 'requested_binding' (Test-Path -LiteralPath $bindingPath -PathType Leaf) $bindingPath
    if (Test-Path -LiteralPath $bindingPath) {
        $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
        Add-Check 'binding_protocol' ($binding.protocol_version -eq 3) ([string]$binding.protocol_version)
        Add-Check 'binding_task_id' ($binding.task_id -eq $TaskId) ([string]$binding.task_id)
        Add-Check 'binding_status' ($binding.status -eq 'READY') ([string]$binding.status)
        Add-Check 'binding_worker' (-not [string]::IsNullOrWhiteSpace([string]$binding.worker_name)) ([string]$binding.worker_name)
        Add-Check 'binding_worker_codename' `
            ([string]$binding.worker_codename -match '^[A-Za-z][A-Za-z0-9_-]{0,31}$') `
            ([string]$binding.worker_codename)
        Add-Check 'binding_mode' ($binding.mode -in @('READ_ONLY', 'WORKSPACE_WRITE')) ([string]$binding.mode)
        Add-Check 'binding_primary_profile' `
            ($binding.primary_profile -in @('ASTRA', 'SOL', 'UNSPECIFIED')) `
            ([string]$binding.primary_profile)
        if ($binding.worker_name -eq 'astra_review_worker') {
            Add-Check 'reviewer_primary_match' `
                ($binding.primary_profile -eq 'SOL' -and $binding.mode -eq 'READ_ONLY') `
                'astra_review_worker requires SOL/READ_ONLY'
        }
        if ($binding.worker_name -eq 'sol_review_worker') {
            Add-Check 'reviewer_primary_match' `
                ($binding.primary_profile -eq 'ASTRA' -and $binding.mode -eq 'READ_ONLY') `
                'sol_review_worker requires ASTRA/READ_ONLY'
        }
        $expectedTaskPath = Join-Path $ProjectRoot ".codex\tasks\$TaskId.md"
        $expectedStatePath = Join-Path $ProjectRoot "work\worker_state\$TaskId.json"
        $boundTaskPath = [IO.Path]::GetFullPath([string]$binding.task_path)
        $boundStatePath = [IO.Path]::GetFullPath([string]$binding.state_path)
        Add-Check 'binding_task_path' ($boundTaskPath -eq [IO.Path]::GetFullPath($expectedTaskPath)) $boundTaskPath
        Add-Check 'binding_state_path' ($boundStatePath -eq [IO.Path]::GetFullPath($expectedStatePath)) $boundStatePath
        $taskExists = ($boundTaskPath -eq [IO.Path]::GetFullPath($expectedTaskPath)) -and
            (Test-Path -LiteralPath $expectedTaskPath -PathType Leaf)
        Add-Check 'bound_task_exists' $taskExists $expectedTaskPath
        if ($taskExists) {
            $hash = (Get-FileHash -LiteralPath $expectedTaskPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Add-Check 'task_hash' ($hash -eq $binding.task_sha256) $hash
        }
        Add-Check 'binding_root' ([IO.Path]::GetFullPath($binding.canonical_root).TrimEnd('\') -eq $ProjectRoot) ([string]$binding.canonical_root)
        $stateExists = ($boundStatePath -eq [IO.Path]::GetFullPath($expectedStatePath)) -and
            (Test-Path -LiteralPath $expectedStatePath -PathType Leaf)
        Add-Check 'bound_state_exists' $stateExists $expectedStatePath
        if ($stateExists) {
            try {
                $state = Get-Content -LiteralPath $expectedStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                Add-Check 'state_protocol' ($state.protocol_version -eq 3) ([string]$state.protocol_version)
                Add-Check 'state_task_id' ($state.task_id -eq $TaskId) ([string]$state.task_id)
                Add-Check 'state_worker' ($state.worker_name -eq $binding.worker_name) ([string]$state.worker_name)
                Add-Check 'state_value' ($state.state -in @('DISPATCHED', 'AGENT_CREATED',
                        'TASK_ACKNOWLEDGED', 'TOOL_STARTED', 'RUNNING', 'OUTPUT_READY',
                        'AGENT_COMPLETED', 'FAILED', 'BLOCKED', 'INTERRUPTED')) ([string]$state.state)
            }
            catch {
                Add-Check 'state_readable' $false $_.Exception.Message
            }
        }
    }
}

foreach ($runtime in @('Rscript', 'node', 'python', 'git')) {
    $cmd = Get-Command $runtime -ErrorAction SilentlyContinue
    if ($cmd) { Add-Check "runtime:$runtime" $true $cmd.Source }
    else { Add-Warning "runtime:$runtime" 'not found; required only when the task uses it' }
}

$config = Join-Path $CodexHome 'config.toml'
Add-Check 'codex_config' (Test-Path -LiteralPath $config -PathType Leaf) $config
$environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
$keyPresent = (Test-Path -LiteralPath 'Env:DEEPSEEK_API_KEY') -or
    ($null -ne $environmentKey -and 'DEEPSEEK_API_KEY' -in $environmentKey.GetValueNames())
if ($null -ne $environmentKey) { $environmentKey.Dispose() }
if (-not $keyPresent) {
    Add-Warning 'deepseek_key' 'missing; required only for a DeepSeek route'
}
else { Add-Check 'deepseek_key' $true 'present; value not read' }

$legacy = Join-Path $ProjectRoot '.codex\deepseek-worker-task.md'
Add-Check 'legacy_mailbox_absent' (-not (Test-Path -LiteralPath $legacy)) $legacy

$checks | Format-Table -AutoSize -Wrap
$failures = @($checks | Where-Object Status -eq 'FAIL')
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
Write-Output "PREFLIGHT_SECONDS=$elapsed"
if ($failures.Count -gt 0) {
    Write-Error "WORKER_PREFLIGHT=FAIL ($($failures.Count) checks)"
    exit 1
}
Write-Output 'WORKER_PREFLIGHT=PASS'
Write-Output 'No API request, worker spawn, or project modification was performed.'
