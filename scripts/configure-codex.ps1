[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GeneratedFragment,
    [Parameter(Mandatory = $true)][string]$TargetUserProfile,
    [Parameter(Mandatory = $true)][string]$KitHome,
    [string]$PythonExe
)

$ErrorActionPreference = 'Stop'
$profileFull = [IO.Path]::GetFullPath($TargetUserProfile).TrimEnd('\')
$actualProfile = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('USERPROFILE')).TrimEnd('\')
$configRoot = Join-Path $profileFull '.codex'
$configPath = Join-Path $configRoot 'config.toml'
$backupRoot = Join-Path $KitHome 'backups'
$beginMarker = '# BEGIN CODEX-STARTER-KIT MANAGED CONFIG v1'
$endMarker = '# END CODEX-STARTER-KIT MANAGED CONFIG v1'

if (-not (Test-Path -LiteralPath $GeneratedFragment -PathType Leaf)) { throw "Generated Codex fragment is missing: $GeneratedFragment" }
$fragment = Get-Content -LiteralPath $GeneratedFragment -Raw -Encoding UTF8
if ($fragment -match '(?i)(app[_-]?secret\s*=|FEISHU_APP_SECRET\s*=\s*["''][^"'']+)') { throw 'Generated Codex fragment contains a literal secret.' }
if ($fragment -match '__[A-Z0-9_]+__') { throw 'Generated Codex fragment contains unresolved placeholders.' }

New-Item -ItemType Directory -Force -Path $configRoot, $backupRoot | Out-Null
$existing = if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 } else { '' }
$managedPattern = '(?ms)^' + [regex]::Escape($beginMarker) + '\r?\n.*?^' + [regex]::Escape($endMarker) + '\r?\n?'
$withoutManaged = [regex]::Replace($existing, $managedPattern, '')
$hasUnmanagedFeishu = [regex]::IsMatch($withoutManaged, '(?m)^\[mcp_servers\.feishu\]\s*$')

if ($hasUnmanagedFeishu) {
    $status = [ordered]@{ merged = $false; status = 'conflict'; configPath = $configPath; reason = 'Existing unmanaged [mcp_servers.feishu] was preserved; review the generated fragment manually.'; backup = $null }
    $status | ConvertTo-Json -Depth 6
    exit 0
}

$newContent = $withoutManaged.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $beginMarker + [Environment]::NewLine + $fragment.Trim() + [Environment]::NewLine + $endMarker + [Environment]::NewLine
$backupPath = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $backupPath = Join-Path $backupRoot ('config.toml.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.bak')
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
}
$tempPath = $configPath + '.tmp-' + [guid]::NewGuid().ToString('N')
try {
    Set-Content -LiteralPath $tempPath -Value $newContent -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($PythonExe)) {
        $candidate = Get-Command python -ErrorAction SilentlyContinue
        if ($candidate) { $PythonExe = $candidate.Source }
    }
    if (-not [string]::IsNullOrWhiteSpace($PythonExe) -and (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        & $PythonExe -c "import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig'))" $tempPath
        if ($LASTEXITCODE -ne 0) { throw 'Merged Codex config failed TOML validation.' }
    }
    Move-Item -LiteralPath $tempPath -Destination $configPath -Force
}
finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
}

[ordered]@{ merged = $true; status = 'merged'; configPath = $configPath; backup = $backupPath; targetIsCurrentUser = $profileFull.Equals($actualProfile, [StringComparison]::OrdinalIgnoreCase) } | ConvertTo-Json -Depth 6
