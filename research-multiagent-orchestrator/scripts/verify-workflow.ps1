[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [switch]$LunaOnly,
    [switch]$ProjectOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    $script:results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}

function Get-TomlScalar([string]$Text, [string]$Key) {
    $values = @(Get-TomlLexedValues $Text '' $Key $true)
    if ($values.Count -ne 1) { return $null }
    $raw = [string]$values[0]
    if ($raw.StartsWith('"')) { return $raw.Substring(1, $raw.Length - 2) }
    return $raw
}

function Get-TomlLexedValues([string]$Text, [string]$Table, [string]$Key, [bool]$AnyTable = $false) {
    $currentTable = ''
    $values = [System.Collections.Generic.List[string]]::new()
    $inBasicMultiline = $false
    $inLiteralMultiline = $false
    foreach ($line in ($Text -split "\r?\n")) {
        $wasInMultiline = $inBasicMultiline -or $inLiteralMultiline
        if (-not $inLiteralMultiline -and ([regex]::Matches($line, '"""').Count % 2 -eq 1)) {
            $inBasicMultiline = -not $inBasicMultiline
        }
        if (-not $inBasicMultiline -and ([regex]::Matches($line, "'''").Count % 2 -eq 1)) {
            $inLiteralMultiline = -not $inLiteralMultiline
        }
        if (-not $wasInMultiline -and -not $inBasicMultiline -and -not $inLiteralMultiline -and
            $line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $matches[1].Trim()
            continue
        }
        if (-not $wasInMultiline -and -not $inBasicMultiline -and -not $inLiteralMultiline -and
            ($AnyTable -or $currentTable -eq $Table) -and
            $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*("(?:[^"\\]|\\.)*"|true|false|[0-9]+)\s*(?:#.*)?$')) {
            $values.Add($matches[1])
        }
    }
    return $values
}

function Get-TomlTableScalar([string]$Text, [string]$Table, [string]$Key) {
    $values = @(Get-TomlLexedValues $Text $Table $Key)
    if ($values.Count -ne 1) { return $null }
    $raw = [string]$values[0]
    if ($raw.StartsWith('"')) { return $raw.Substring(1, $raw.Length - 2) }
    return $raw
}

$config = Join-Path $CodexHome 'config.toml'
Add-Check 'config' $(if (Test-Path -LiteralPath $config -PathType Leaf) { 'PASS' } else { 'FAIL' }) $config
if (Test-Path -LiteralPath $config -PathType Leaf) {
    $text = Get-Content -LiteralPath $config -Raw -Encoding UTF8
    Add-Check 'agents_enabled' $(if ((Get-TomlTableScalar $text 'agents' 'enabled') -eq 'true') { 'PASS' } else { 'FAIL' }) 'agents.enabled=true'
    Add-Check 'agents_serial' $(if ((Get-TomlTableScalar $text 'agents' 'max_concurrent_threads_per_session') -eq '1') { 'PASS' } else { 'FAIL' }) 'agents.max_concurrent_threads_per_session=1'
    if (-not $LunaOnly) {
        $providerChecks = [ordered]@{
            name = 'DeepSeek'; base_url = 'https://api.deepseek.com/'; wire_api = 'responses'
            env_key = 'DEEPSEEK_API_KEY'; supports_websockets = 'false'
        }
        foreach ($providerEntry in $providerChecks.GetEnumerator()) {
            Add-Check "deepseek_provider:$($providerEntry.Key)" `
                $(if ((Get-TomlTableScalar $text 'model_providers.deepseek' $providerEntry.Key) -eq $providerEntry.Value) { 'PASS' } else { 'FAIL' }) `
                $([string]$providerEntry.Value)
        }
    }
}

$agentNames = @('luna-medium-worker.toml', 'luna-high-worker.toml', 'luna-max-worker.toml',
    'terra-readonly-fallback-worker.toml', 'terra-fallback-worker.toml')
if (-not $LunaOnly) {
    $agentNames = @('deepseek-context-worker.toml', 'deepseek-context-reasoning-worker.toml',
        'deepseek-batch-worker.toml') + $agentNames
}
foreach ($name in $agentNames) {
    $path = Join-Path (Join-Path $CodexHome 'agents') $name
    Add-Check "agent:$name" $(if (Test-Path -LiteralPath $path -PathType Leaf) { 'PASS' } else { 'FAIL' }) $path
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $agentText = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $expectedName = [IO.Path]::GetFileNameWithoutExtension($name) -replace '-', '_'
        Add-Check "agent_name:$name" `
            $(if ((Get-TomlScalar $agentText 'name') -eq $expectedName) { 'PASS' } else { 'FAIL' }) $expectedName
        $expectedSandbox = if ($name -like 'deepseek-context*' -or
            $name -eq 'terra-readonly-fallback-worker.toml') { 'read-only' } else { 'workspace-write' }
        Add-Check "agent_sandbox:$name" `
            $(if ((Get-TomlScalar $agentText 'sandbox_mode') -eq $expectedSandbox) { 'PASS' } else { 'FAIL' }) $expectedSandbox
        if ($name -like 'deepseek-*') {
            Add-Check "agent_provider:$name" `
                $(if ((Get-TomlScalar $agentText 'model_provider') -eq 'deepseek') { 'PASS' } else { 'FAIL' }) 'deepseek'
            Add-Check "agent_model:$name" `
                $(if ((Get-TomlScalar $agentText 'model') -eq 'deepseek-v4-flash') { 'PASS' } else { 'FAIL' }) 'deepseek-v4-flash'
        }
    }
}

$agentModelSpecs = [ordered]@{
    'deepseek-context-worker.toml' = @('deepseek-v4-flash', 'low')
    'deepseek-context-reasoning-worker.toml' = @('deepseek-v4-flash', 'high')
    'deepseek-batch-worker.toml' = @('deepseek-v4-flash', 'high')
    'luna-medium-worker.toml' = @('gpt-5.6-luna', 'medium')
    'luna-high-worker.toml' = @('gpt-5.6-luna', 'high')
    'luna-max-worker.toml' = @('gpt-5.6-luna', 'max')
    'terra-readonly-fallback-worker.toml' = @('gpt-5.6-terra', 'high')
    'terra-fallback-worker.toml' = @('gpt-5.6-terra', 'high')
}
foreach ($entry in $agentModelSpecs.GetEnumerator()) {
    if ($LunaOnly -and $entry.Key -like 'deepseek-*') { continue }
    $path = Join-Path (Join-Path $CodexHome 'agents') $entry.Key
    $agentText = if (Test-Path -LiteralPath $path -PathType Leaf) {
        Get-Content -LiteralPath $path -Raw -Encoding UTF8
    } else { '' }
    Add-Check "agent_model_exact:$($entry.Key)" `
        $(if ((Get-TomlScalar $agentText 'model') -eq $entry.Value[0]) { 'PASS' } else { 'FAIL' }) $entry.Value[0]
    Add-Check "agent_effort:$($entry.Key)" `
        $(if ((Get-TomlScalar $agentText 'model_reasoning_effort') -eq $entry.Value[1]) { 'PASS' } else { 'FAIL' }) $entry.Value[1]
    Add-Check "agent_instructions:$($entry.Key)" `
        $(if ($agentText -match '(?m)^developer_instructions\s*=\s*"""') { 'PASS' } else { 'FAIL' }) 'developer_instructions present'
}

$globalAgents = Join-Path $CodexHome 'AGENTS.md'
if (-not $ProjectOnly) {
    Add-Check 'global_agents' $(if (Test-Path -LiteralPath $globalAgents -PathType Leaf) { 'PASS' } else { 'FAIL' }) $globalAgents
}
if (-not $ProjectOnly -and (Test-Path -LiteralPath $globalAgents -PathType Leaf)) {
    $globalText = Get-Content -LiteralPath $globalAgents -Raw -Encoding UTF8
    $globalMigrated = ($globalText -match 'research-multiagent-orchestrator-global:start') -and
        ($globalText -notmatch 'Use the `deepseek_worker` custom subagent') -and
        ($globalText -notmatch 'Write the complete bounded assignment to `\.codex/deepseek-worker-task\.md`')
    Add-Check 'legacy_global_protocol_absent' `
        $(if ($globalMigrated) { 'PASS' } else { 'FAIL' }) `
        'legacy positive routing instructions must be absent'
}

$descriptor = Join-Path $ProjectRoot '.codex\research-multiagent.toml'
Add-Check 'descriptor' $(if (Test-Path -LiteralPath $descriptor -PathType Leaf) { 'PASS' } else { 'FAIL' }) $descriptor
if (Test-Path -LiteralPath $descriptor -PathType Leaf) {
    $descriptorText = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8
    Add-Check 'protocol_version' `
        $(if ($descriptorText -match '(?m)^protocol_version\s*=\s*3\s*$') { 'PASS' } else { 'FAIL' }) `
        'protocol_version=3'
    $expectedDeepSeek = if ($LunaOnly) { 'false' } else { 'true' }
    Add-Check 'deepseek_mode' `
        $(if ($descriptorText -match "(?m)^deepseek_enabled\s*=\s*$expectedDeepSeek\s*$") { 'PASS' } else { 'FAIL' }) `
        "deepseek_enabled=$expectedDeepSeek"
    $rootToml = $ProjectRoot.Replace('\', '/')
    Add-Check 'descriptor_root' `
        $(if ($descriptorText -match ('(?m)^canonical_root\s*=\s*"' + [regex]::Escape($rootToml) + '"\s*$')) { 'PASS' } else { 'FAIL' }) $rootToml
    $expectedScope = if ($ProjectOnly) { 'project-only' } else { 'user-and-project' }
    Add-Check 'installation_scope' `
        $(if ($descriptorText -match ('(?m)^installation_scope\s*=\s*"' + $expectedScope + '"\s*$')) { 'PASS' } else { 'FAIL' }) $expectedScope
}
foreach ($relative in @('.codex\tasks', '.codex\bindings', 'work\worker_state')) {
    $path = Join-Path $ProjectRoot $relative
    Add-Check "directory:$relative" $(if (Test-Path -LiteralPath $path -PathType Container) { 'PASS' } else { 'FAIL' }) $path
}

$agentsMd = Join-Path $ProjectRoot 'AGENTS.md'
$agentsOk = (Test-Path -LiteralPath $agentsMd -PathType Leaf) -and
    (Select-String -LiteralPath $agentsMd -SimpleMatch 'research-multiagent-orchestrator:start' -Quiet)
Add-Check 'project_instructions' $(if ($agentsOk) { 'PASS' } else { 'FAIL' }) $agentsMd

$legacy = Join-Path $ProjectRoot '.codex\deepseek-worker-task.md'
Add-Check 'legacy_mailbox_absent' $(if (-not (Test-Path -LiteralPath $legacy)) { 'PASS' } else { 'FAIL' }) $legacy

$ready = @()
$taskDir = Join-Path $ProjectRoot '.codex\tasks'
if (Test-Path -LiteralPath $taskDir -PathType Container) {
    $ready = @(Get-ChildItem -LiteralPath $taskDir -Filter '*.md' -File | Where-Object {
        Select-String -LiteralPath $_.FullName -Pattern '^Status:\s*READY\s*$' -Quiet
    })
}
Add-Check 'ready_tasks' $(if ($ready.Count -le 1) { 'PASS' } else { 'FAIL' }) "count=$($ready.Count)"

if (-not $LunaOnly) {
    $environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    $keyPresent = (Test-Path -LiteralPath 'Env:DEEPSEEK_API_KEY') -or
        ($null -ne $environmentKey -and 'DEEPSEEK_API_KEY' -in $environmentKey.GetValueNames())
    if ($null -ne $environmentKey) { $environmentKey.Dispose() }
    Add-Check 'deepseek_key' $(if ($keyPresent) { 'PASS' } else { 'FAIL' }) `
        $(if ($keyPresent) { 'present; value hidden' } else { 'missing; run set-deepseek-key.ps1 and restart Codex' })
}

$results | Format-Table -AutoSize -Wrap
$failed = @($results | Where-Object Status -eq 'FAIL')
if ($failed.Count -gt 0) {
    Write-Error "WORKFLOW_STATIC_CHECK=FAIL ($($failed.Count) checks)"
    exit 1
}
Write-Output 'WORKFLOW_STATIC_CHECK=PASS'
Write-Output 'No API request or project modification was performed.'
