[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
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
$descriptor = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
Add-Check 'descriptor' (Test-Path -LiteralPath $descriptor -PathType Leaf) $descriptor
if (Test-Path -LiteralPath $descriptor) {
    $descriptorText = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8
    $rootToml = $ProjectRoot.Replace('\', '/')
    Add-Check 'descriptor_root_matches' ($descriptorText -match ('canonical_root\s*=\s*"' + [regex]::Escape($rootToml) + '"')) $rootToml
}

$bindingDir = Join-Path $ProjectRoot '.codex\bindings'
$bindings = if (Test-Path $bindingDir) { @(Get-ChildItem -LiteralPath $bindingDir -Filter '*.json' -File) } else { @() }
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
        $taskExists = Test-Path -LiteralPath $binding.task_path -PathType Leaf
        Add-Check 'bound_task_exists' $taskExists ([string]$binding.task_path)
        if ($taskExists) {
            $hash = (Get-FileHash -LiteralPath $binding.task_path -Algorithm SHA256).Hash.ToLowerInvariant()
            Add-Check 'task_hash' ($hash -eq $binding.task_sha256) $hash
        }
        Add-Check 'binding_root' ([IO.Path]::GetFullPath($binding.canonical_root).TrimEnd('\') -eq $ProjectRoot) ([string]$binding.canonical_root)
    }
}

foreach ($runtime in @('Rscript', 'node', 'python', 'git')) {
    $cmd = Get-Command $runtime -ErrorAction SilentlyContinue
    if ($cmd) { Add-Check "runtime:$runtime" $true $cmd.Source }
    else { Add-Warning "runtime:$runtime" 'not found; required only when the task uses it' }
}

$config = Join-Path $CodexHome 'config.toml'
Add-Check 'codex_config' (Test-Path -LiteralPath $config -PathType Leaf) $config
$key = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
if ([string]::IsNullOrWhiteSpace($key)) {
    Add-Warning 'deepseek_key_user_scope' 'missing; required only for a DeepSeek route'
}
else { Add-Check 'deepseek_key_user_scope' $true 'present; value hidden' }
$key = $null

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
