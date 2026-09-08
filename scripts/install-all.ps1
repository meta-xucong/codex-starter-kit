[CmdletBinding()]
param(
    [string]$TargetUserProfile
)

$ErrorActionPreference = 'Stop'

$packRoot = $PSScriptRoot
$installer = Join-Path $packRoot 'install-to-codex.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "安装器不存在: $installer"
}

$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $installer,
    '-PackRoot', $packRoot,
    '-IncludeNonDefault',
    '-IncludeUnsupported',
    '-Overwrite'
)

if (-not [string]::IsNullOrWhiteSpace($TargetUserProfile)) {
    $arguments += @('-TargetUserProfile', $TargetUserProfile)
}

$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
& $powershell @arguments
exit $LASTEXITCODE
