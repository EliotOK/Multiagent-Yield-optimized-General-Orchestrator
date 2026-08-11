[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    $script:results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}

$config = Join-Path $CodexHome 'config.toml'
Add-Check 'config' $(if (Test-Path $config) { 'PASS' } else { 'FAIL' }) $config
if (Test-Path $config) {
    $text = Get-Content -LiteralPath $config -Raw -Encoding UTF8
    Add-Check 'agents_enabled' $(if ($text -match '(?ms)^\[agents\].*?^enabled\s*=\s*true') { 'PASS' } else { 'FAIL' }) 'agents.enabled=true'
    Add-Check 'deepseek_provider' $(if ($text -match '(?ms)^\[model_providers\.deepseek\].*?^env_key\s*=\s*"DEEPSEEK_API_KEY"') { 'PASS' } else { 'FAIL' }) 'provider uses environment key'
}

foreach ($name in @('deepseek-context-worker.toml', 'deepseek-context-reasoning-worker.toml', 'deepseek-batch-worker.toml',
        'luna-medium-worker.toml', 'luna-high-worker.toml', 'luna-max-worker.toml',
        'terra-fallback-worker.toml')) {
    $path = Join-Path (Join-Path $CodexHome 'agents') $name
    Add-Check "agent:$name" $(if (Test-Path $path) { 'PASS' } else { 'FAIL' }) $path
}

$lunaEfforts = [ordered]@{
    'luna-medium-worker.toml' = 'medium'
    'luna-high-worker.toml' = 'high'
    'luna-max-worker.toml' = 'max'
}
foreach ($entry in $lunaEfforts.GetEnumerator()) {
    $path = Join-Path (Join-Path $CodexHome 'agents') $entry.Key
    $ok = (Test-Path $path) -and
        ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -match
            ('(?m)^model_reasoning_effort\s*=\s*"' + [regex]::Escape($entry.Value) + '"\s*$'))
    Add-Check "luna_effort:$($entry.Value)" $(if ($ok) { 'PASS' } else { 'FAIL' }) $path
}

$globalAgents = Join-Path $CodexHome 'AGENTS.md'
Add-Check 'global_agents' $(if (Test-Path $globalAgents) { 'PASS' } else { 'FAIL' }) $globalAgents
if (Test-Path $globalAgents) {
    $globalText = Get-Content -LiteralPath $globalAgents -Raw -Encoding UTF8
    $globalMigrated = ($globalText -match 'research-multiagent-orchestrator-global:start') -and
        ($globalText -notmatch 'Use the `deepseek_worker` custom subagent') -and
        ($globalText -notmatch 'Write the complete bounded assignment to `\.codex/deepseek-worker-task\.md`')
    Add-Check 'legacy_global_protocol_absent' `
        $(if ($globalMigrated) { 'PASS' } else { 'FAIL' }) `
        'legacy positive routing instructions must be absent'
}

$descriptor = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
Add-Check 'descriptor' $(if (Test-Path $descriptor) { 'PASS' } else { 'FAIL' }) $descriptor
if (Test-Path $descriptor) {
    $descriptorText = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8
    Add-Check 'protocol_version' `
        $(if ($descriptorText -match '(?m)^protocol_version\s*=\s*3\s*$') { 'PASS' } else { 'FAIL' }) `
        'protocol_version=3'
}
foreach ($relative in @('.codex\tasks', '.codex\bindings', 'work\worker_state')) {
    $path = Join-Path $ProjectRoot $relative
    Add-Check "directory:$relative" $(if (Test-Path $path -PathType Container) { 'PASS' } else { 'FAIL' }) $path
}

$agentsMd = Join-Path $ProjectRoot 'AGENTS.md'
$agentsOk = (Test-Path $agentsMd) -and
    (Select-String -LiteralPath $agentsMd -SimpleMatch 'research-multiagent-orchestrator:start' -Quiet)
Add-Check 'project_instructions' $(if ($agentsOk) { 'PASS' } else { 'FAIL' }) $agentsMd

$legacy = Join-Path $ProjectRoot '.codex\deepseek-worker-task.md'
Add-Check 'legacy_mailbox_absent' $(if (-not (Test-Path $legacy)) { 'PASS' } else { 'FAIL' }) $legacy

$ready = @()
$taskDir = Join-Path $ProjectRoot '.codex\tasks'
if (Test-Path $taskDir) {
    $ready = @(Get-ChildItem -LiteralPath $taskDir -Filter '*.md' -File | Where-Object {
        Select-String -LiteralPath $_.FullName -Pattern '^Status:\s*READY\s*$' -Quiet
    })
}
Add-Check 'ready_tasks' $(if ($ready.Count -le 1) { 'PASS' } else { 'FAIL' }) "count=$($ready.Count)"

$key = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
$keyStatus = if ([string]::IsNullOrWhiteSpace($key)) { 'WARN' } else { 'PASS' }
Add-Check 'deepseek_key_user_scope' $keyStatus $(if ($keyStatus -eq 'PASS') { 'present; value hidden' } else { 'missing at User scope' })
$key = $null

$results | Format-Table -AutoSize -Wrap
$failed = @($results | Where-Object Status -eq 'FAIL')
if ($failed.Count -gt 0) {
    Write-Error "WORKFLOW_STATIC_CHECK=FAIL ($($failed.Count) checks)"
    exit 1
}
Write-Output 'WORKFLOW_STATIC_CHECK=PASS'
Write-Output 'No API request or project modification was performed.'
