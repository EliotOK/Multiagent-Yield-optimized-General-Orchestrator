[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'

$environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
$existing = $null -ne $environmentKey -and
    'DEEPSEEK_API_KEY' -in $environmentKey.GetValueNames()
if ($null -ne $environmentKey) { $environmentKey.Dispose() }
if ($Check) {
    Write-Output $(if (-not $existing) {
        'DEEPSEEK_API_KEY_USER_SCOPE=MISSING'
    } else {
        'DEEPSEEK_API_KEY_USER_SCOPE=PRESENT'
    })
    $existing = $null
    exit 0
}
$existingKeyPresent = $existing
$existing = $null

if (-not [Environment]::UserInteractive) {
    throw 'Run this script in an interactive PowerShell terminal.'
}

if ($existingKeyPresent) {
    $confirmation = Read-Host 'A user-level DEEPSEEK_API_KEY already exists. Type REPLACE to overwrite it'
    if ($confirmation -cne 'REPLACE') {
        throw 'Existing key was preserved; nothing was changed.'
    }
}

Write-Host 'Enter the DeepSeek API key. Input is hidden and is not written to command history.'
$secure = Read-Host 'DEEPSEEK_API_KEY' -AsSecureString
if ($null -eq $secure -or $secure.Length -eq 0) {
    throw 'No key was entered; nothing was changed.'
}

$bstr = [IntPtr]::Zero
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw 'No key was entered; nothing was changed.'
    }
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $plain, 'User')
}
finally {
    $plain = $null
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $secure.Dispose()
}

Write-Output 'DEEPSEEK_API_KEY_USER_SCOPE=SET'
Write-Output 'The value was hidden during entry and was not printed.'
Write-Warning 'Windows user environment variables are not an encrypted secret vault. Protect the Windows account and never place the key in prompts, commands, files, or logs.'
Write-Output 'Fully restart Codex Desktop before installing or using DeepSeek workers.'
