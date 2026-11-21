[CmdletBinding()]
param([string]$RepositoryRoot = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$SkillRoot = Join-Path $RepositoryRoot 'mygo'
$PluginSkillRoot = Join-Path $RepositoryRoot 'plugins\mygo\skills\mygo'
foreach ($legacySkillRoot in @(
    (Join-Path $RepositoryRoot 'research-multiagent-orchestrator'),
    (Join-Path $RepositoryRoot 'plugins\mygo\skills\research-multiagent-orchestrator')
)) {
    if (Test-Path -LiteralPath $legacySkillRoot) {
        throw "Legacy skill directory must not coexist with mygo: $legacySkillRoot"
    }
}

foreach ($relative in @('README.md', 'README.zh-CN.md')) {
    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required bilingual repository file is missing: $path"
    }
}

foreach ($relative in @(
    'SKILL.md', 'agents\openai.yaml', 'scripts\install-workflow.ps1', 'scripts\consult.py',
    'scripts\set-deepseek-key.ps1',
    'scripts\configure-model-map.ps1',
    'scripts\resolve-primary-profile.ps1',
    'scripts\update-task-state.ps1',
    'scripts\create-task.ps1', 'scripts\close-task.ps1',
    'references\primary-profiles.md', 'references\model-map.md',
    'references\model-routing.md', 'references\legacy-workflow.md',
    'assets\project\mygo-model-map.json',
    'assets\agents\deepseek-context-worker.toml',
    'assets\agents\deepseek-context-reasoning-worker.toml',
    'assets\agents\deepseek-batch-worker.toml',
    'assets\agents\luna-medium-worker.toml',
    'assets\agents\luna-high-worker.toml',
    'assets\agents\luna-max-worker.toml',
    'assets\agents\terra-readonly-fallback-worker.toml',
    'assets\agents\terra-fallback-worker.toml',
    'assets\agents\astra-review-worker.toml',
    'assets\agents\sol-review-worker.toml'
)) {
    $path = Join-Path $SkillRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release file is missing: $path"
    }
}

foreach ($skill in @($SkillRoot, $PluginSkillRoot)) {
    $skillText = Get-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Raw -Encoding UTF8
    if ($skillText -notmatch '(?s)^---\s*\r?\nname:\s*mygo\s*\r?\ndescription:\s*.+?\r?\n---') {
        throw "SKILL.md frontmatter is missing the expected mygo name and description: $skill"
    }
    $agentManifest = Get-Content -LiteralPath (Join-Path $skill 'agents\openai.yaml') -Raw -Encoding UTF8
    if ($agentManifest -notmatch '(?m)^\s*default_prompt:\s*".*\$mygo\b.*"\s*$') {
        throw "agents/openai.yaml does not invoke the mygo skill: $skill"
    }
}

$sourceFiles = @(Get-ChildItem -LiteralPath $SkillRoot -Recurse -File | ForEach-Object {
    [pscustomobject]@{
        RelativePath = $_.FullName.Substring($SkillRoot.Length + 1)
        Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$pluginFiles = @(Get-ChildItem -LiteralPath $PluginSkillRoot -Recurse -File | ForEach-Object {
    [pscustomobject]@{
        RelativePath = $_.FullName.Substring($PluginSkillRoot.Length + 1)
        Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$copyDifferences = @(Compare-Object -ReferenceObject $sourceFiles -DifferenceObject $pluginFiles `
    -Property RelativePath, Hash)
if ($copyDifferences.Count -gt 0) {
    $copyDifferences | Format-Table -AutoSize | Out-String | Write-Error
    throw 'The root and plugin skill copies differ.'
}

foreach ($workerFile in @('deepseek-batch-worker.toml', 'luna-medium-worker.toml',
        'luna-high-worker.toml', 'luna-max-worker.toml')) {
    $workerText = Get-Content -LiteralPath (Join-Path $SkillRoot "assets\agents\$workerFile") -Raw -Encoding UTF8
    if ($workerText -notmatch 'update-task-state\.ps1' -or
        $workerText -notmatch 'never\s+edit\s+the\s+(worker-state\s+)?JSON\s+directly') {
        throw "Write worker does not enforce the state transition helper: $workerFile"
    }
}

$parseErrors = @()
Get-ChildItem -LiteralPath (Join-Path $SkillRoot 'scripts') -Filter '*.ps1' -File | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { $parseErrors += $errors }
}
if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-List | Out-String | Write-Error
    throw 'PowerShell parser validation failed.'
}

python -c "import pathlib,tomllib; root=pathlib.Path(r'$SkillRoot'); [tomllib.loads(p.read_text(encoding='utf-8')) for p in root.rglob('*.toml')]; print('TOML_PARSE=PASS')"
if ($LASTEXITCODE -ne 0) { throw 'TOML parser validation failed.' }

python -B -m unittest discover -s (Join-Path $RepositoryRoot 'tests') -p 'test_consult.py'
if ($LASTEXITCODE -ne 0) { throw 'Direct vendor API regression tests failed.' }

python -B -m unittest discover -s (Join-Path $RepositoryRoot 'tests') -p 'test_plugin.py'
if ($LASTEXITCODE -ne 0) { throw 'Plugin and native V2 setup regression tests failed.' }

$textFiles = Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -ne $PSCommandPath -and
    $_.Extension -in '.md', '.ps1', '.toml', '.yaml', '.yml', '.txt', '.json',
        '.py', '.sh', '.cfg', '.ini', '.csv', '.tsv'
}
$forbidden = $textFiles | Select-String -Pattern '(?i)[a-z]:\\users\\|/users/[^/]+/|\\\\[^\\]+\\users\\|\bsk-[A-Za-z0-9_-]{16,}\b|BEGIN (RSA |OPENSSH )?PRIVATE KEY|DEEPSEEK_API_KEY\s*=\s*["''][^<\s][^"'']+["'']' -List
if ($forbidden) {
    $forbidden | ForEach-Object { Write-Error "Release privacy scan match: $($_.Path):$($_.LineNumber)" }
    throw 'Release privacy scan failed.'
}

$englishReadme = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'README.md') -Raw -Encoding UTF8
$chineseReadme = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'README.zh-CN.md') -Raw -Encoding UTF8
foreach ($requiredText in @('v0.1.0-beta.4', 'ProjectOnly', 'LunaOnly',
        'security-regression.ps1', 'APPROVED_EXTERNAL', 'terra_readonly_fallback_worker',
        'MYGO', 'Astra primary', 'Sol primary', 'deepseek-flash', 'codex plugin marketplace add',
        'codex plugin add mygo@mygo')) {
    if ($englishReadme -notmatch [regex]::Escape($requiredText) -or
        $chineseReadme -notmatch [regex]::Escape($requiredText)) {
        throw "Bilingual documentation parity check failed for: $requiredText"
    }
}

Write-Output 'PACKAGE_VALIDATE=PASS'
