[CmdletBinding()]
param([string]$RepositoryRoot = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$SkillRoot = Join-Path $RepositoryRoot 'research-multiagent-orchestrator'

foreach ($relative in @('README.md', 'README.zh-CN.md')) {
    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required bilingual repository file is missing: $path"
    }
}

foreach ($relative in @(
    'SKILL.md', 'agents\openai.yaml', 'scripts\install-workflow.ps1',
    'scripts\set-deepseek-key.ps1',
    'scripts\create-task.ps1', 'scripts\close-task.ps1',
    'assets\agents\luna-medium-worker.toml',
    'assets\agents\luna-high-worker.toml',
    'assets\agents\luna-max-worker.toml'
)) {
    $path = Join-Path $SkillRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release file is missing: $path"
    }
}

$skillText = Get-Content -LiteralPath (Join-Path $SkillRoot 'SKILL.md') -Raw -Encoding UTF8
if ($skillText -notmatch '(?s)^---\s*\r?\nname:\s*research-multiagent-orchestrator\s*\r?\ndescription:\s*.+?\r?\n---') {
    throw 'SKILL.md frontmatter is missing the expected name and description.'
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

$textFiles = Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File | Where-Object {
    $_.Extension -in '.md', '.ps1', '.toml', '.yaml', '.yml', '.txt'
}
$forbidden = $textFiles | Select-String -Pattern '(?i)[a-z]:\\users\\|\bsk-[A-Za-z0-9_-]{16,}\b|BEGIN (RSA |OPENSSH )?PRIVATE KEY' -List
if ($forbidden) {
    $forbidden | ForEach-Object { Write-Error "Release privacy scan match: $($_.Path):$($_.LineNumber)" }
    throw 'Release privacy scan failed.'
}

Write-Output 'PACKAGE_VALIDATE=PASS'
