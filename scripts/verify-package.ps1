[CmdletBinding()]
param(
    [switch]$SkipRebuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot

if (-not $SkipRebuild) {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Verification requires Python 3. The installer itself does not.' }
    & $python.Source (Join-Path $repoRoot 'scripts\build-pack.py') --check
    if ($LASTEXITCODE -ne 0) { throw 'Pack build failed.' }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing JSON file: $Path" }
    return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Resolve-PackFile([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Unsafe pack path: $RelativePath"
    }
    $packRootFull = [IO.Path]::GetFullPath((Join-Path $repoRoot 'installer-pack')).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $repoRoot (Join-Path 'installer-pack' ($RelativePath -replace '/', '\'))))
    if (-not $candidate.StartsWith($packRootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Pack path escapes root: $RelativePath" }
    return $candidate
}

$audit = Read-JsonFile (Join-Path $repoRoot 'manifest\skill-audit.json')
$agentAudit = Read-JsonFile (Join-Path $repoRoot 'manifest\agent-audit.json')
$pack = Read-JsonFile (Join-Path $repoRoot 'installer-pack\pack.json')
$dependencies = Read-JsonFile (Join-Path $repoRoot 'installer-pack\dependencies.json')
$fileManifest = Read-JsonFile (Join-Path $repoRoot 'installer-pack\file-manifest.json')
$runtimeArtifacts = Read-JsonFile (Join-Path $repoRoot 'manifest\runtime-artifacts.json')
$mcpServers = Read-JsonFile (Join-Path $repoRoot 'manifest\mcp-servers.json')
$feishuTools = Read-JsonFile (Join-Path $repoRoot 'manifest\feishu-tools.json')
$apiServices = Read-JsonFile (Join-Path $repoRoot 'manifest\api-services.json')
$connectionFields = Read-JsonFile (Join-Path $repoRoot 'manifest\connection-fields.json')

if ([int]$pack.schemaVersion -ne 2) { throw 'Pack schema must be 2.' }
if ([string]$pack.version -ne '1.2.0') { throw "Unexpected pack version: $($pack.version)" }
if ([string]$pack.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'Pack source commit must be a 40-character Git commit.' }
if ([string]$pack.sourceCommitRole -notin @('git-head','upstream-base')) { throw 'Pack source commit role is invalid.' }
if ([string]$pack.sourceTreeSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Pack source tree SHA-256 is missing or invalid.' }
if ([string]$pack.compatibleCodex.minCodexVersion -ne '0.144.0') { throw 'Minimum Codex version contract changed unexpectedly.' }
if ([string]$pack.compatibleCodex.testedCodexVersion -ne '0.147.0') { throw 'Tested Codex version contract changed unexpectedly.' }
if (@($pack.statuses) -join ',' -ne 'auto-installable-runtime,core-ready,guided-config,unsupported') { throw 'Pack statuses must use the post-remediation enum.' }
if (@($pack.sourceStatuses) -join ',' -ne 'ready,requires-credential,requires-mcp,requires-runtime,unsupported/disabled') { throw 'Pack sourceStatuses must preserve the audit enum separately.' }

$manifestSkills = @(Get-Content -LiteralPath (Join-Path $repoRoot 'manifest\imported-skills.txt') -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim() })
$auditSkills = @($audit.skills | ForEach-Object { [string]$_.id })
$packSkills = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'installer-pack\skills') -Directory | ForEach-Object { $_.Name })
$agents = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'agents') -Filter '*.toml' -File)
$packAgents = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'installer-pack\agents') -Filter '*.toml' -File)

Write-Host "Source skills: $($manifestSkills.Count)"
Write-Host "Audited skills: $($auditSkills.Count)"
Write-Host "Pack skills: $($packSkills.Count)"
Write-Host "Source agents: $($agents.Count)"
Write-Host "Pack agents: $($packAgents.Count)"

if ($manifestSkills.Count -ne 50 -or $auditSkills.Count -ne 50 -or $packSkills.Count -ne 50) { throw 'Expected exactly 50 skills.' }
if (@(Compare-Object ($manifestSkills | Sort-Object) ($auditSkills | Sort-Object)).Count -gt 0) { throw 'Skill manifest and audit differ.' }
if (@(Compare-Object ($manifestSkills | Sort-Object) ($packSkills | Sort-Object)).Count -gt 0) { throw 'Skill manifest and pack differ.' }
if ($agents.Count -ne 7 -or $packAgents.Count -ne 7) { throw 'Expected exactly 7 agents.' }

$statusCounts = @{}
$afterCounts = @{}
foreach ($skill in $audit.skills) {
    $status = [string]$skill.status
    $after = [string]$skill.afterRemediationStatus
    if (-not $statusCounts.ContainsKey($status)) { $statusCounts[$status] = 0 }
    if (-not $afterCounts.ContainsKey($after)) { $afterCounts[$after] = 0 }
    $statusCounts[$status]++
    $afterCounts[$after]++
    if ($skill.installByDefault -and $after -ne 'core-ready') { throw "Non-core skill installed by default: $($skill.id)" }
}
foreach ($expected in @{
    'core-ready' = 25
    'auto-installable-runtime' = 14
    'guided-config' = 7
    'unsupported' = 4
}.GetEnumerator()) {
    if (-not $afterCounts.ContainsKey($expected.Key) -or $afterCounts[$expected.Key] -ne $expected.Value) { throw "Unexpected after-remediation count for $($expected.Key)." }
}

$names = [System.Collections.Generic.HashSet[string]]::new()
foreach ($skill in $manifestSkills) {
    $doc = Join-Path (Join-Path $repoRoot 'skills') (Join-Path $skill 'SKILL.md')
    if (-not (Test-Path -LiteralPath $doc -PathType Leaf)) { throw "Missing SKILL.md: $skill" }
    $content = Get-Content -LiteralPath $doc -Encoding UTF8 -Raw
    $nameMatch = [regex]::Match($content, '(?m)^name:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*$')
    $descriptionMatch = [regex]::Match($content, '(?m)^description:\s*(.+)')
    if (-not $nameMatch.Success -or $nameMatch.Groups[1].Value.Trim() -ne $skill) { throw "Skill name mismatch: $skill" }
    if (-not $descriptionMatch.Success -or [string]::IsNullOrWhiteSpace($descriptionMatch.Groups[1].Value.Trim().Trim('"'))) { throw "Skill description missing: $skill" }
    if (-not $names.Add($nameMatch.Groups[1].Value.Trim())) { throw "Duplicate skill name: $skill" }
    $packDoc = Join-Path (Join-Path $repoRoot 'installer-pack\skills') (Join-Path $skill 'SKILL.md')
    if (-not (Test-Path -LiteralPath $packDoc -PathType Leaf)) { throw "Pack SKILL.md missing: $skill" }
}

$nonCore = @($audit.skills | Where-Object { $_.afterRemediationStatus -ne 'core-ready' })
foreach ($skill in $nonCore) {
    $yaml = Join-Path (Join-Path (Join-Path $repoRoot 'skills') $skill.id) 'agents\openai.yaml'
    if (-not (Test-Path -LiteralPath $yaml -PathType Leaf)) { throw "Non-core Skill metadata missing: $($skill.id)" }
    $yamlText = Get-Content -LiteralPath $yaml -Encoding UTF8 -Raw
    if ($yamlText -notmatch '(?m)^\s*allow_implicit_invocation:\s*false\s*$') { throw "Non-core Skill must disable implicit invocation: $($skill.id)" }
    $packYaml = Join-Path (Join-Path (Join-Path $repoRoot 'installer-pack\skills') $skill.id) 'agents\openai.yaml'
    if (-not (Test-Path -LiteralPath $packYaml -PathType Leaf)) { throw "Pack Skill metadata missing: $($skill.id)" }
}

$forbidden = '(?i)(open' + 'claw|claw' + 'dbot|ran' + 'claw|\.open' + 'claw)'
$secretLike = '(?i)(sk-[A-Za-z0-9]{20,}|Bearer\s+[A-Za-z0-9._-]{20,})'
function Scan-TextRoots([string[]]$Roots) {
    foreach ($scanRoot in $Roots) {
        $absolute = if ([IO.Path]::IsPathRooted($scanRoot)) { $scanRoot } else { Join-Path $repoRoot $scanRoot }
        if (-not (Test-Path -LiteralPath $absolute)) { continue }
        $files = if (Test-Path -LiteralPath $absolute -PathType Leaf) { @((Get-Item -LiteralPath $absolute)) } else { @(Get-ChildItem -LiteralPath $absolute -Recurse -File) }
        foreach ($file in $files) {
            if ($file.Name -eq '.DS_Store' -or $file.Name -like '*_tasks.json' -or $file.Name -like '*.json.lock' -or $file.Name -like '*-market.json' -or $file.FullName -match '\\(__pycache__|\.cache|drafts|output|codex-data)(\\|$)') { continue }
            if ($file.Extension.ToLowerInvariant() -notin @('.md','.py','.js','.ts','.json','.toml','.ps1','.sh','.txt','.yaml','.yml','.lock','.in')) { continue }
            $text = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw
            if ($text -match $forbidden) { throw "Legacy marker found: $($file.FullName)" }
            if ($text -match $secretLike) { throw "Secret-like value found: $($file.FullName)" }
        }
    }
}
Scan-TextRoots @('README.md', 'ENVIRONMENT-MCP-INVENTORY.md', 'agents', 'docs', 'manifest', 'scripts', 'skills', 'runtime', 'config-fragments')
Scan-TextRoots @((Join-Path $repoRoot 'installer-pack'))

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'installer-pack\runtime\requirements-python-win-x64-py312.in') -PathType Leaf)) { throw 'Pack Python direct requirements input missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'installer-pack\runtime\wheelhouse-manifest.json') -PathType Leaf)) { throw 'Pack wheelhouse manifest missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'installer-pack\manifest\runtime-artifacts.json') -PathType Leaf)) { throw 'Pack runtime artifact manifest missing.' }
foreach ($runtimeScript in @('materialize-python-wheelhouse.py','materialize-python-wheelhouse.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot ('installer-pack\runtime\' + $runtimeScript)) -PathType Leaf)) { throw "Pack runtime materializer missing: $runtimeScript" }
}
foreach ($requiredPackFile in @(
    'mcp\mcp-servers.json',
    'mcp\api-services.json',
    'mcp\connection-fields.json',
    'mcp\start-feishu-mcp.ps1',
    'test-adapter-contracts.py',
    'manifest\feishu-tools.json',
    'config-fragments\README.md',
    'config-fragments\feishu-official-stdio.template.toml',
    'docs\CODEX-ADAPTATION-DEVELOPMENT.md',
    'docs\KNOWN-LIMITATIONS.md',
    'install-to-codex.ps1',
    'render-codex-config.ps1',
    'audit-codex-compatibility.py'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot ('installer-pack\' + $requiredPackFile)) -PathType Leaf)) { throw "Pack extension file missing: $requiredPackFile" }
}
foreach ($readmePath in @(
    (Join-Path $repoRoot 'README.md'),
    (Join-Path $repoRoot 'installer-pack\README.md')
)) {
    $readmeText = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
    if ($readmeText -notmatch 'docs/KNOWN-LIMITATIONS\.md') { throw "Known-limitations link missing: $readmePath" }
}
if (@($runtimeArtifacts.artifacts).Count -ne 4) { throw 'Expected Python, wheelhouse, optional Node and locked MCP package artifact records.' }
foreach ($artifact in $runtimeArtifacts.artifacts) {
    if ([string]$artifact.materializationStatus -ne 'pending' -or [bool]$artifact.installReady) { throw "Unmaterialized runtime artifact cannot be install-ready: $($artifact.artifactId)" }
}
$wheelManifest = Read-JsonFile (Join-Path $repoRoot 'runtime\wheelhouse-manifest.json')
if ([string]$wheelManifest.materializationStatus -ne 'pending' -or [bool]$wheelManifest.installReady -or [bool]$wheelManifest.transitiveClosure.complete) { throw 'Public wheelhouse manifest must remain pending until private materialization.' }
if ([string]$wheelManifest.abi -ne 'cp312' -or [string]$wheelManifest.platform -ne 'win_amd64') { throw 'Wheelhouse ABI/platform contract is not cp312/win_amd64.' }
if (@($mcpServers.servers).Count -ne 1 -or [string]$mcpServers.servers[0].id -ne 'feishu') { throw 'MCP inventory must contain the guided Feishu server record.' }
if ([string]$feishuTools.toolNameCase -ne 'dot' -or (@($feishuTools.readTools).Count + @($feishuTools.writeTools).Count) -ne 25) { throw 'Feishu tool contract must contain 25 dot-case tools.' }
if (@($apiServices.services).Count -ne 3) { throw 'Expected three direct API service records.' }
if (@($connectionFields.fields).Count -ne 18) { throw 'Expected eighteen guided connection fields, including explicit external models, gateway routing, and Seedance policy fields.' }

if ([int]$dependencies.schemaVersion -ne 2) { throw 'Dependency schema must be 2.' }
$dependencyIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($dependency in $dependencies.dependencyCatalog) {
    if ([string]::IsNullOrWhiteSpace([string]$dependency.id) -or [string]::IsNullOrWhiteSpace([string]$dependency.kind)) { throw 'Dependency catalog entry lacks id/kind.' }
    if (-not $dependencyIds.Add([string]$dependency.id)) { throw "Duplicate dependency catalog id: $($dependency.id)" }
}
foreach ($skillEntry in $dependencies.skills) {
    foreach ($dependencyId in @($skillEntry.dependencies)) {
        if (-not $dependencyIds.Contains([string]$dependencyId)) { throw "Skill dependency not in catalog: $($skillEntry.id) -> $dependencyId" }
    }
}
foreach ($agentEntry in $dependencies.agents) {
    foreach ($dependency in @($agentEntry.dependencies)) {
        if (-not $dependencyIds.Contains([string]$dependency.id)) { throw "Agent dependency not in catalog: $($agentEntry.id) -> $($dependency.id)" }
    }
    foreach ($blockedSkill in @($agentEntry.blockedSkills)) {
        $blockedDependency = @($agentEntry.dependencies | Where-Object { ([string]$_.id) -eq ('skill.' + $blockedSkill) })[0]
        if (-not $blockedDependency -or -not [bool]$blockedDependency.blocked -or [bool]$blockedDependency.autoInstallable) { throw "Blocked Agent Skill is executable: $($agentEntry.id) -> $blockedSkill" }
    }
}
if (@($dependencies.skills).Count -ne 50 -or @($dependencies.agents).Count -ne 7) { throw 'Dependency closure does not cover 50 skills and 7 agents.' }

$defaultSkills = @($pack.defaultEnabled.skills)
$auditDefaultSkills = @($audit.skills | Where-Object { $_.installByDefault } | ForEach-Object { $_.id })
if (@(Compare-Object ($defaultSkills | Sort-Object) ($auditDefaultSkills | Sort-Object)).Count -gt 0) { throw 'Pack default skills differ from audit installByDefault.' }
foreach ($skill in $defaultSkills) {
    $item = @($audit.skills | Where-Object { $_.id -eq $skill })[0]
    if (-not $item -or $item.afterRemediationStatus -ne 'core-ready' -or -not $item.installByDefault) { throw "Invalid default skill status: $skill" }
}

foreach ($entry in $fileManifest.files) {
    $path = Resolve-PackFile ([string]$entry.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Manifest file missing: $($entry.path)" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne ([string]$entry.sha256).ToLowerInvariant()) { throw "Hash mismatch: $($entry.path)" }
}

$checksumFile = Join-Path $repoRoot 'installer-pack\checksums.sha256'
if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) { throw 'checksums.sha256 is missing.' }
$checksumPaths = [System.Collections.Generic.HashSet[string]]::new()
foreach ($line in Get-Content -LiteralPath $checksumFile -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $match = [regex]::Match($line, '^(?<hash>[0-9a-fA-F]{64}) \*(?<path>.+)$')
    if (-not $match.Success) { throw "Invalid checksum line: $line" }
    $relative = $match.Groups['path'].Value.Trim()
    if (-not $checksumPaths.Add($relative)) { throw "Duplicate checksum path: $relative" }
    $path = Resolve-PackFile $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Checksum file missing: $relative" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $match.Groups['hash'].Value.ToLowerInvariant()) { throw "Checksum mismatch: $relative" }
}
$allPackFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'installer-pack') -Recurse -File | ForEach-Object { $_.FullName.Substring((Join-Path $repoRoot 'installer-pack').Length + 1).Replace('\','/') } | Where-Object { $_ -ne 'checksums.sha256' })
if (@(Compare-Object ($allPackFiles | Sort-Object) (@($checksumPaths) | Sort-Object)).Count -gt 0) { throw 'checksums.sha256 does not cover every pack file.' }

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'Verification requires Python 3 for syntax checks.' }
foreach ($auditRoot in @($repoRoot, (Join-Path $repoRoot 'installer-pack'))) {
    & $python.Source (Join-Path $repoRoot 'scripts\audit-codex-compatibility.py') --root $auditRoot --require-codex
    if ($LASTEXITCODE -ne 0) { throw "Codex compatibility audit failed: $auditRoot" }
}
$pyFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'skills') -Recurse -Filter '*.py' -File) + @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.py' -File)
foreach ($pyFile in $pyFiles) {
    & $python.Source -m py_compile $pyFile.FullName
    if ($LASTEXITCODE -ne 0) { throw "Python syntax check failed: $($pyFile.FullName)" }
}
& $python.Source -c "import tomllib, pathlib; [tomllib.loads(p.read_text(encoding='utf-8')) for p in pathlib.Path('agents').glob('*.toml')]"
if ($LASTEXITCODE -ne 0) { throw 'Agent TOML parse failed.' }

$psParser = [System.Management.Automation.Language.Parser]
$psFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'skills') -Recurse -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File)
foreach ($psFile in $psFiles) {
    $tokens = $null
    $errors = $null
    $null = $psParser::ParseFile($psFile.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell syntax check failed: $($psFile.FullName)" }
}

$smokeRoot = Join-Path $repoRoot ('.verify-smoke-' + [guid]::NewGuid().ToString('N'))
$oldWeatherData = $env:WEATHER_DATA_DIR
$oldCodexData = $env:CODEX_DATA_DIR
$oldFeishuAppId = $env:FEISHU_APP_ID
$oldFeishuAppSecret = $env:FEISHU_APP_SECRET
$oldFeishuUserToken = $env:FEISHU_USER_ACCESS_TOKEN
$oldCodexHomePath = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
try {
    New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null
    $ps = (Get-Command powershell -ErrorAction SilentlyContinue)
    if (-not $ps) { throw 'Windows PowerShell is required for the PowerShell smoke tests.' }
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\python-env-setup\scripts\check_python_env.ps1') -Json | ConvertFrom-Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Python environment smoke test failed.' }
    # Use an ASCII folder-name token so Windows PowerShell 5.1 cannot misdecode a UTF-8/no-BOM Chinese literal.
    $searchJson = & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\skills-search\scripts\skills_search.ps1') -Keyword 'video' -Root $repoRoot -Json | ConvertFrom-Json
    if (@($searchJson).Count -lt 1) { throw 'Skill search smoke test returned no result.' }
    $env:WEATHER_DATA_DIR = Join-Path $smokeRoot 'weather'
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\weather-forecast\scripts\weather_db.ps1') -Command set_city -City 'Shanghai' | Out-Null
    $city = & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\weather-forecast\scripts\weather_db.ps1') -Command get_city
    if ([string]$city -ne 'Shanghai') { throw 'Weather persistence smoke test failed.' }
    $env:CODEX_DATA_DIR = $smokeRoot
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\daily-reflection\scripts\reflection.ps1') -Command health | ConvertFrom-Json | Out-Null
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\daily-reflection\scripts\reflection.ps1') -Command log -Text 'verification smoke test' -Energy 7 -Focus 8 | ConvertFrom-Json | Out-Null
    $summary = & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'skills\daily-reflection\scripts\reflection.ps1') -Command summary | ConvertFrom-Json
    if (@($summary).Count -lt 1) { throw 'Reflection storage smoke test failed.' }

    & $python.Source (Join-Path $repoRoot 'skills\wechat-article-creator\scripts\start_article.py') '..\..\unsafe title' --topic 'verification' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'WeChat article storage smoke test failed.' }
    $articleDraftRoot = Join-Path $smokeRoot 'wechat-article-creator\drafts'
    $articleDrafts = @(Get-ChildItem -LiteralPath $articleDraftRoot -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($articleDrafts.Count -ne 1 -or $articleDrafts[0].Name -notmatch '_unsafe_title\.md$') { throw 'WeChat article filename/path normalization contract failed.' }
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'skills\wechat-article-creator\drafts')) { throw 'WeChat article smoke test wrote into the installed Skill tree.' }

    & $python.Source (Join-Path $repoRoot 'skills\web-content-fetcher\scripts\fetch.py') --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Web content fetcher --help smoke test failed without optional imports.' }

    $oldPythonDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
    try {
        $env:PYTHONDONTWRITEBYTECODE = '1'
        foreach ($adapterTest in @(
            (Join-Path $repoRoot 'scripts\test-adapter-contracts.py'),
            (Join-Path $repoRoot 'installer-pack\test-adapter-contracts.py')
        )) {
            & $python.Source $adapterTest
            if ($LASTEXITCODE -ne 0) { throw "External HTTP adapter contract tests failed: $adapterTest" }
        }
    }
    finally {
        $env:PYTHONDONTWRITEBYTECODE = $oldPythonDontWriteBytecode
    }

    $env:FEISHU_APP_ID = 'cli_verification_only'
    $env:FEISHU_APP_SECRET = 'verification-secret&never-a-command'
    Remove-Item Env:FEISHU_USER_ACCESS_TOKEN -ErrorAction SilentlyContinue
    $wrapperOutput = & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\start-feishu-mcp.ps1') -PackageCache (Join-Path $smokeRoot 'feishu-cache') -DryRun | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Feishu wrapper dry-run failed.' }
    if ($wrapperOutput -match [regex]::Escape($env:FEISHU_APP_SECRET)) { throw 'Feishu wrapper dry-run leaked the test secret.' }
    $wrapperPlan = $wrapperOutput | ConvertFrom-Json
    if ([bool]$wrapperPlan.secretsRendered -or @($wrapperPlan.tools).Count -ne 25 -or [string]$wrapperPlan.toolNameCase -ne 'dot' -or -not [bool]$wrapperPlan.nodeReady) { throw 'Feishu wrapper dry-run contract is invalid.' }

    $renderedConfig = Join-Path $smokeRoot 'codex-fragment.toml'
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\render-codex-config.ps1') -OutputPath $renderedConfig | ConvertFrom-Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Codex config rendering smoke test failed.' }
    $renderedText = Get-Content -LiteralPath $renderedConfig -Raw -Encoding UTF8
    if ($renderedText -match '__[A-Z0-9_]+__' -or $renderedText -match [regex]::Escape($env:FEISHU_APP_SECRET)) { throw 'Rendered Codex config contains a placeholder or secret.' }
    & $python.Source -c "import pathlib,sys,tomllib; d=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig')); assert not d['mcp_servers']['feishu']['enabled']; assert len(d['mcp_servers']['feishu']['enabled_tools']) == 25" $renderedConfig
    if ($LASTEXITCODE -ne 0) { throw 'Rendered Codex config TOML contract failed.' }

    $fakePackageRoot = Join-Path $smokeRoot 'feishu-cache\node_modules\@larksuiteoapi\lark-mcp'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakePackageRoot 'dist') | Out-Null
    [ordered]@{ name = '@larksuiteoapi/lark-mcp'; version = '0.5.1' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakePackageRoot 'package.json') -Encoding UTF8
    '// verification-only CLI placeholder; never executed' | Set-Content -LiteralPath (Join-Path $fakePackageRoot 'dist\cli.js') -Encoding UTF8
    $enabledConfig = Join-Path $smokeRoot 'codex-feishu-enabled.toml'
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\render-codex-config.ps1') -OutputPath $enabledConfig -EnableFeishu -FeishuWrapperPath (Join-Path $repoRoot 'scripts\start-feishu-mcp.ps1') -FeishuPackageCache (Join-Path $smokeRoot 'feishu-cache') | ConvertFrom-Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Enabled Feishu config rendering smoke test failed.' }
    $enabledText = Get-Content -LiteralPath $enabledConfig -Raw -Encoding UTF8
    if ($enabledText -match [regex]::Escape($env:FEISHU_APP_SECRET)) { throw 'Enabled Feishu config leaked the test secret.' }
    & $python.Source -c "import pathlib,sys,tomllib; d=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig')); s=d['mcp_servers']['feishu']; assert s['enabled']; assert s['env_vars']==['FEISHU_APP_ID','FEISHU_APP_SECRET']; assert s['default_tools_approval_mode']=='writes'; assert all(s['tools'][x]['approval_mode']=='prompt' for x in ['drive.v1.file.delete','drive.v1.permissionMember.delete','drive.v1.permissionMember.transferOwner'])" $enabledConfig
    if ($LASTEXITCODE -ne 0) { throw 'Enabled Feishu config approval contract failed.' }

    $env:FEISHU_USER_ACCESS_TOKEN = 'verification-user-token'
    $userModeConfig = Join-Path $smokeRoot 'codex-feishu-user.toml'
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\render-codex-config.ps1') -OutputPath $userModeConfig -EnableFeishu -FeishuWrapperPath (Join-Path $repoRoot 'scripts\start-feishu-mcp.ps1') -FeishuPackageCache (Join-Path $smokeRoot 'feishu-cache') -FeishuAuthMode user | ConvertFrom-Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'User-token Feishu config rendering smoke test failed.' }
    & $python.Source -c "import pathlib,sys,tomllib; s=tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig'))['mcp_servers']['feishu']; assert s['env_vars']==['FEISHU_APP_ID','FEISHU_APP_SECRET','FEISHU_USER_ACCESS_TOKEN']; assert s['args'][-1]=='user'" $userModeConfig
    if ($LASTEXITCODE -ne 0) { throw 'User-token Feishu least-privilege environment contract failed.' }
    Remove-Item Env:FEISHU_USER_ACCESS_TOKEN -ErrorAction SilentlyContinue

    $codexConfigHome = Join-Path $smokeRoot 'codex-home'
    New-Item -ItemType Directory -Force -Path $codexConfigHome | Out-Null
    Copy-Item -LiteralPath $renderedConfig -Destination (Join-Path $codexConfigHome 'config.toml') -Force
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexConfigHome, 'Process')
        $codexMcp = & codex mcp get feishu --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Codex rejected the rendered MCP configuration.' }
        if ([bool]$codexMcp.enabled -or @($codexMcp.enabled_tools).Count -ne 25 -or @($codexMcp.transport.env_vars).Count -ne 2 -or [string]$codexMcp.transport.command -ne 'powershell.exe') { throw 'Codex parsed MCP configuration differs from the rendered contract.' }
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHomePath, 'Process')
    }

    $isolatedProfile = Join-Path $smokeRoot 'profile'
    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'installer-pack\install-to-codex.ps1') -PackRoot (Join-Path $repoRoot 'installer-pack') -TargetUserProfile $isolatedProfile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Isolated installer smoke test failed.' }
    $installedSkillCount = @(Get-ChildItem -LiteralPath (Join-Path $isolatedProfile '.agents\skills') -Directory).Count
    $installedAgentCount = @(Get-ChildItem -LiteralPath (Join-Path $isolatedProfile '.codex\agents') -Filter '*.toml' -File).Count
    if ($installedSkillCount -ne 25 -or $installedAgentCount -ne 7) { throw "Isolated install count mismatch: skills=$installedSkillCount agents=$installedAgentCount" }
    if (Test-Path -LiteralPath (Join-Path $isolatedProfile '.agents\skills\pdf-processing-toolkit')) { throw 'Unsupported PDF Skill was installed by default.' }
    foreach ($installedSupportFile in @(
        '.codex\codex-agent-kit\bin\start-feishu-mcp.ps1',
        '.codex\codex-agent-kit\bin\render-codex-config.ps1',
        '.codex\codex-agent-kit\bin\audit-codex-compatibility.py',
        '.codex\codex-agent-kit\readiness.json',
        '.codex\codex-agent-kit\install-manifest.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $isolatedProfile $installedSupportFile) -PathType Leaf)) { throw "Isolated install support file missing: $installedSupportFile" }
    }
    $readiness = Read-JsonFile (Join-Path $isolatedProfile '.codex\codex-agent-kit\readiness.json')
    if ([int]$readiness.installed.skills -ne 25 -or [int]$readiness.installed.agents -ne 7 -or [bool]$readiness.secretsStored) { throw 'Isolated readiness report is inconsistent.' }

    $locallyModifiedAgent = @(Get-ChildItem -LiteralPath (Join-Path $isolatedProfile '.codex\agents') -Filter '*.toml' -File | Sort-Object Name)[0].FullName
    Add-Content -LiteralPath $locallyModifiedAgent -Value "`n# local-verification-change"
    $skillWithUserFile = @(Get-ChildItem -LiteralPath (Join-Path $isolatedProfile '.agents\skills') -Directory | Sort-Object Name)[0].FullName
    $userAddedSkillFile = Join-Path $skillWithUserFile 'local-user-note.txt'
    'preserve me' | Set-Content -LiteralPath $userAddedSkillFile -Encoding UTF8

    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'installer-pack\install-to-codex.ps1') -PackRoot (Join-Path $repoRoot 'installer-pack') -TargetUserProfile $isolatedProfile -IncludeNonDefault -Overwrite | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Non-default isolated installer smoke test failed.' }
    $installedSkillCount = @(Get-ChildItem -LiteralPath (Join-Path $isolatedProfile '.agents\skills') -Directory).Count
    if ($installedSkillCount -ne 46) { throw "Non-default install should exclude four unsupported Skills; found $installedSkillCount." }
    foreach ($unsupportedSkill in @('canvas','healthcheck','node-connect','pdf-processing-toolkit')) {
        if (Test-Path -LiteralPath (Join-Path $isolatedProfile ('.agents\skills\' + $unsupportedSkill))) { throw "Unsupported Skill installed without explicit acceptance: $unsupportedSkill" }
    }
    if ((Get-Content -LiteralPath $locallyModifiedAgent -Raw) -notmatch 'local-verification-change') { throw 'Installer overwrote a locally modified Agent.' }
    if (-not (Test-Path -LiteralPath $userAddedSkillFile -PathType Leaf)) { throw 'Installer removed a user-added Skill file.' }

    & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'installer-pack\install-to-codex.ps1') -PackRoot (Join-Path $repoRoot 'installer-pack') -TargetUserProfile $isolatedProfile -IncludeNonDefault -IncludeUnsupported -Overwrite | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Explicit unsupported-content isolated installer smoke test failed.' }
    $installedSkillCount = @(Get-ChildItem -LiteralPath (Join-Path $isolatedProfile '.agents\skills') -Directory).Count
    if ($installedSkillCount -ne 50) { throw "Explicit unsupported install count mismatch: $installedSkillCount" }
    $readiness = Read-JsonFile (Join-Path $isolatedProfile '.codex\codex-agent-kit\readiness.json')
    if ([int]$readiness.installed.skills -ne 50 -or -not [bool]$readiness.requested.includeUnsupported) { throw 'Unsupported-content readiness report is inconsistent.' }

    $tamperedPack = Join-Path $smokeRoot 'tampered-pack'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'installer-pack') -Destination $tamperedPack -Recurse
    'unlisted' | Set-Content -LiteralPath (Join-Path $tamperedPack 'unlisted-file.txt') -Encoding UTF8
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $tamperResult = & $ps.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tamperedPack 'install-to-codex.ps1') -PackRoot $tamperedPack -TargetUserProfile (Join-Path $smokeRoot 'tamper-profile') 2>&1
        $tamperExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($tamperExitCode -eq 0) { throw 'Installer accepted a pack containing an unlisted file.' }
    if (($tamperResult | Out-String) -notmatch 'unlisted|missing') { throw 'Installer rejected a tampered pack without a useful error.' }
    Write-Host 'PowerShell smoke tests passed.' -ForegroundColor Green
}
finally {
    $env:WEATHER_DATA_DIR = $oldWeatherData
    $env:CODEX_DATA_DIR = $oldCodexData
    $env:FEISHU_APP_ID = $oldFeishuAppId
    $env:FEISHU_APP_SECRET = $oldFeishuAppSecret
    $env:FEISHU_USER_ACCESS_TOKEN = $oldFeishuUserToken
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHomePath, 'Process')
    if (Test-Path -LiteralPath $smokeRoot) { Remove-Item -LiteralPath $smokeRoot -Recurse -Force }
}

Write-Host 'Status counts:' -ForegroundColor Cyan
$audit.skills | Group-Object status | Sort-Object Name | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) }
Write-Host 'After-remediation counts:' -ForegroundColor Cyan
$audit.skills | Group-Object afterRemediationStatus | Sort-Object Name | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) }
Write-Host "Default skills: $($defaultSkills.Count)"
Write-Host "Runtime artifacts: $(@($runtimeArtifacts.artifacts).Count); MCP servers: $(@($mcpServers.servers).Count); API services: $(@($apiServices.services).Count)"
Write-Host 'Package verification passed.' -ForegroundColor Green
