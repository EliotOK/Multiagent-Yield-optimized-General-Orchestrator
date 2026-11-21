param(
    [Parameter(Mandatory = $true)][string]$Provider,
    [Parameter(Mandatory = $true)][ValidateSet('environment', 'prompt')][string]$Source,
    [ValidateSet('coding', 'api')][string]$Plan = 'coding',
    [Parameter(Mandatory = $true)][string]$Python,
    [Parameter(Mandatory = $true)][string]$Helper,
    [Parameter(Mandatory = $true)][string]$Magpie
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'MYGO - local credential import'
& $Python -B $Helper --provider $Provider --source $Source --plan $Plan --magpie $Magpie
$exitCode = $LASTEXITCODE
Write-Host ''
if ($exitCode -ne 0) { Read-Host 'Press Enter to close' }
exit $exitCode
