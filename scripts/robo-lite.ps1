# lite 판 굽기 — **공용 `robo.ps1` 의 release 경로를 건드리지 않는다.**
#
# 왜 따로 있나
#   공용 release 는 **enterprise 앱 모양**에 맞춰져 있다 — 이미지 **열 개**를
#   리터럴로 들고, 이미지마다 빌드 줄이 하나씩 손으로 적혀 있고, 앱 매니페스트
#   템플릿이 그 열 개를 **다 선언했는지** 검사한다.
#
#   lite 앱은 **일곱 서비스**다(실측 2026-10-29):
#     graph-db · graph-bolt · fabric · catalog · analyzer · parser · gateway
#   없는 것은 **authority**(계정·프로젝트 게이트웨이) · **pdf2bpmn** · **wireframe**.
#   lite 에는 인증 기능이 **아예 없다**(api/features/auth 0파일 · LoginView 0개).
#   그래서 공용 경로는 lite 를 "서비스를 빠뜨렸다" 고 보고 거절한다 — 그 검사는
#   enterprise 에서 **옳다**. 느슨하게 만들지 않고, 이 줄기를 따로 둔다.
#
# ⚠ 이 파일은 공용 `robo.ps1` 을 **읽기만** 한다(dot-source). 함수와 설정을
#   물려받되 공용 release 흐름은 호출하지 않는다. 그래서 enterprise 납품 굽기는
#   이 파일이 있든 없든 **글자 하나 달라지지 않는다**.
#
# 쓰는 법
#   .\robo-lite.cmd            (또는) powershell -File scripts\robo-lite.ps1
#   -SkipSbom  구성품 목록을 건너뛴다 (빠른 반복용. 납품에는 쓰지 않는다)

[CmdletBinding()]
param([switch]$SkipSbom)

$ErrorActionPreference = 'Stop'

# ── 공용 스크립트에서 함수·설정을 물려받는다 ─────────────────────────
#    `help architect-electron` 으로 부르면 **아무 일도 하지 않고** 초기화만 한다
#    (tests/environment-contract.ps1 이 같은 방법을 쓴다).
. (Join-Path $PSScriptRoot 'robo.ps1') help architect-electron *> $null

Info 'lite 판을 굽는다 — 공용 release 경로는 쓰지 않는다'

# ── lite 가 짓는 이미지 일곱 ─────────────────────────────────────────
#    ⚠ 이 표가 곧 lite 의 모양이다. 서비스를 더하거나 빼면 **여기와 앱의
#      매니페스트 템플릿을 같이** 고친다 — 아래 검사가 어긋나면 바로 선다.
$LiteImageBuilds = @(
  @{ key = 'graphDb';   repo = 'ontological'; kind = 'target';     arg = 'runtime-db' }
  @{ key = 'graphBolt'; repo = 'ontological'; kind = 'target';     arg = 'runtime-bolt' }
  @{ key = 'analyzer';  repo = 'analyzer';    kind = 'image' }
  @{ key = 'catalog';   repo = 'catalog';     kind = 'image' }
  @{ key = 'fabric';    repo = 'fabric';      kind = 'image' }
  @{ key = 'parser';    repo = 'parser';      kind = 'image' }
  @{ key = 'gateway';   repo = 'gateway';     kind = 'image' }
)
$LiteImageNames = @{
  graphDb   = 'uengine/ontological-db'
  graphBolt = 'uengine/ontological-bolt'
  analyzer  = 'uengine/robo-analyzer'
  catalog   = 'uengine/robo-data-catalog'
  fabric    = 'uengine/robo-data-fabric'
  parser    = 'uengine/robo-antlr-parser'
  gateway   = 'uengine/robo-api-gateway'
}
# lite compose 가 env_file 로 읽는 묶음. pdf2bpmn 은 **lite 에 없다**.
$LiteEnvironmentScopes = @('analyzer', 'catalog', 'fabric', 'parser', 'gateway', 'architect')

# ── 1. 소스를 맞추고 깨끗한지 본다 (공용 함수 그대로) ────────────────
Prepare-ReleaseWorkspace
$sources = Get-ReleaseSources
Info 'checking immutable release inputs'
Assert-ReleaseSourceState $sources
Invoke-Checked 'docker.exe' @('info', '--format', '{{.ServerVersion}}') $WorkspaceRoot
Assert-NoRunningDesktopApp $sources.architect

$commits = [ordered]@{}
foreach ($entry in $sources.GetEnumerator()) { $commits[$entry.Key] = Get-GitCommit $entry.Value }

# ── 2. 릴리스 id — 공용과 **같은 규칙**이어야 한다 ───────────────────
#    같은 규칙을 쓰는 이유: 두 줄기의 폴더·태그가 같은 이름 공간에 살기 때문이다.
#    구별은 **갈래 꼬리**(`-lite`)가 한다. `ROBO_RELEASE_VARIANT` 를 안 주면
#    enterprise 판과 **같은 이름**이 나와 서로 덮어쓴다 — 그래서 여기서 강제한다.
$desktopPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $sources.architect 'desktop\package.json') | ConvertFrom-Json
$otherCommits = @(
  $commits.GetEnumerator() |
    Where-Object { $_.Key -notin @('workspace', 'architect') } |
    Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }
) -join "`n"
$sourceDigest = if ($otherCommits) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    ([System.BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($otherCommits))) -replace '-', '').ToLowerInvariant().Substring(0, 6)
  } finally { $sha.Dispose() }
} else { '000000' }

$posture = Get-ReleaseAuthPosture (Read-EnvironmentFile $WorkspaceEnvPath)
$variant = [string]$posture.variant
if ([String]::IsNullOrWhiteSpace($variant)) {
  throw ("lite.variant_required: `.env` 에 ROBO_RELEASE_VARIANT 를 주어라(예: lite). " +
         "비우면 enterprise 판과 **같은 릴리스 id** 가 나와 폴더와 도커 태그를 덮어쓴다")
}
$channelTag = if ($posture.channel -eq 'delivery') { 'del' } else { 'int' }
$providerTag = if ($posture.authProvider -eq 'swp') { 'swp' } else { 'none' }
$releaseId = '{0}-w{1}-a{2}-s{3}-r{4}-{5}-{6}' -f $desktopPackage.version,
  $commits.workspace.Substring(0, 8), $commits.architect.Substring(0, 8), $sourceDigest,
  $channelTag, $providerTag, $variant
Info "release id: $releaseId"

$images = [ordered]@{}
foreach ($b in $LiteImageBuilds) { $images[$b.key] = "$($LiteImageNames[$b.key]):$releaseId" }

$runtimeRoot = Join-Path $sources.architect 'desktop\resources\runtime'
$releaseRoot = Join-Path $WorkspaceRoot "_releases\$releaseId"
$imageArchive = Join-Path $runtimeRoot 'robo-images.tar'

# ── 3. 앱 템플릿이 **우리가 쓰는 키를 다 선언했나** ──────────────────
#    공용과 같은 검사를 lite 집합으로 돈다. 이름으로 말하므로, 서비스를 하나
#    더할 때 여기서 먼저 문다.
$templatePath = Join-Path $sources.architect 'desktop\runtime\runtime-manifest.template.json'
if (-not (Test-Path -LiteralPath $templatePath)) { throw "lite.manifest_template_missing: $templatePath" }
$templateProbe = Get-Content -Raw -Encoding UTF8 $templatePath | ConvertFrom-Json
Assert-ManifestTemplateCovers $templateProbe '(최상위)' `
  @('releaseId', 'releaseChannel', 'releaseVariant', 'imageArchiveSha256') $templatePath
Assert-ManifestTemplateCovers $templateProbe.source   'source'   @($commits.Keys)  $templatePath
Assert-ManifestTemplateCovers $templateProbe.images   'images'   @($images.Keys)   $templatePath
Assert-ManifestTemplateCovers $templateProbe.imageIds 'imageIds' @($images.Keys)   $templatePath
Assert-ManifestTemplateCovers $templateProbe.environment 'environment' $LiteEnvironmentScopes $templatePath
# ⚠ 거꾸로도 본다 — 템플릿이 **우리가 안 짓는 이미지**를 선언하면 설치본이
#   없는 이미지를 찾는다. 공용 경로에는 이 방향 검사가 없다(열 개를 다 짓기 때문).
$declaredImages = @($templateProbe.images.PSObject.Properties.Name)
$weDoNotBuild = @($declaredImages | Where-Object { $_ -notin $images.Keys })
if ($weDoNotBuild.Count) {
  throw ("lite.manifest_declares_unbuilt_images: $($weDoNotBuild -join ', ') — " +
         "템플릿이 선언했는데 이 스크립트가 짓지 않는다. 둘을 맞춰라")
}
Pass 'manifest template matches the lite image set (both directions)'

Check-ReleaseEnvironment

# ── 4. 이미지 일곱을 짓는다 ──────────────────────────────────────────
foreach ($b in $LiteImageBuilds) {
  $tag = $images[$b.key]
  $repoPath = $sources[$b.repo]
  $repoCommit = $commits[$b.repo]
  if (-not $repoPath) { throw "lite.unknown_source_repo: $($b.repo)" }
  if ($b.kind -eq 'target') { Build-ReleaseTarget $b.key $tag $repoPath $repoCommit $b.arg }
  else { Build-ReleaseImage $b.key $tag $repoPath $repoCommit }
}

# ── 5. 번들 Architect API 런타임 ─────────────────────────────────────
Info 'building bundled Architect API runtime'
$psHostPath = (Get-Process -Id $PID).Path
if (-not $psHostPath) { $psHostPath = 'powershell.exe' }
Info "packaged runtime host: $psHostPath"
Invoke-Checked $psHostPath @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', (Join-Path $sources.architect 'scripts\build-packaged-runtime.ps1'),
  '-OutputRoot', $runtimeRoot
) $sources.architect

# ── 6. compose — lite 는 **하나**다 ──────────────────────────────────
#    공용은 셋을 싣는다(bundled · remote-graph overlay · central-db). lite 에는
#    중앙 모드가 **없다**(그 파일들이 저장소에 아예 없다). 개인이 자기 PC 에서
#    DB 까지 띄우는 bundled 하나뿐이다.
$composeSource = Join-Path $sources.architect 'desktop\runtime\compose.yml'
if (-not (Test-Path -LiteralPath $composeSource)) { throw "lite.missing_compose: $composeSource" }
Copy-Item -LiteralPath $composeSource -Destination (Join-Path $runtimeRoot 'compose.yml') -Force
foreach ($stray in @('compose.remote-graph.yml', 'compose.central-db.yml',
                     'central-authority.env.example', 'CENTRAL-SERVER.md')) {
  $p = Join-Path $runtimeRoot $stray
  if (Test-Path -LiteralPath $p) {
    # enterprise 판을 구운 뒤 같은 폴더에 남아 있을 수 있다. 남기면 설치본이
    # **있지도 않은 중앙 모드**를 들고 나간다.
    Warn "removing enterprise-only runtime artifact: $stray"
    Remove-Item -LiteralPath $p -Force
  }
}

# ── 7. 서비스별 환경 스냅샷 ──────────────────────────────────────────
Info 'writing service-scoped packaged environment'
$environmentResult = Write-ReleaseEnvironmentSnapshots $runtimeRoot
$environmentSnapshots = [ordered]@{}
foreach ($k in $environmentResult.snapshots.Keys) {
  if ($k -in $LiteEnvironmentScopes) { $environmentSnapshots[$k] = $environmentResult.snapshots[$k] }
  else {
    # 공용 계약은 pdf2bpmn 묶음까지 쓴다. lite compose 는 그 파일을 읽지 않으니
    # **치운다** — 안 치우면 설치본에 쓰이지 않는 env 가 실려 나간다.
    $orphan = Join-Path $runtimeRoot ([string]$environmentResult.snapshots[$k].file)
    if (Test-Path -LiteralPath $orphan) { Remove-Item -LiteralPath $orphan -Force }
    Info "skipping environment scope not used by lite: $k"
  }
}
$withheldCredentials = @($environmentResult.withheld)
if ($withheldCredentials.Count) {
  Info ("withholding credentials from the package ($($withheldCredentials.Count)): " +
        ($withheldCredentials -join ', '))
}

# ── 8. 이미지 묶음 ───────────────────────────────────────────────────
Info 'creating offline Docker image archive'
Invoke-Checked 'docker.exe' (@('save', '--output', $imageArchive) + @($images.Values)) $WorkspaceRoot
$archiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $imageArchive).Hash.ToLowerInvariant()

# ── 9. 매니페스트 ────────────────────────────────────────────────────
$manifest = Get-Content -Raw -Encoding UTF8 $templatePath | ConvertFrom-Json
$manifest.releaseId = $releaseId
$manifest.imageArchiveSha256 = $archiveSha
$manifest.releaseChannel = [string]$posture.channel
$manifest.releaseVariant = $variant
# ⚠ lite 에는 인증이 **없다.** 공용 판처럼 자세를 싣지만 값은 그 사실대로 둔다 —
#   여기에 true 를 넣으면 "로그인이 있는 판" 으로 **거짓 기록**이 된다.
$manifest | Add-Member -NotePropertyName authEnforced -NotePropertyValue $false -Force
$manifest | Add-Member -NotePropertyName authProvider -NotePropertyValue 'none' -Force
$manifest | Add-Member -NotePropertyName credentialNames -NotePropertyValue $withheldCredentials -Force
foreach ($k in $commits.Keys) { $manifest.source.$k = [string]$commits[$k] }
foreach ($k in $images.Keys) {
  $manifest.images.$k = [string]$images[$k]
  $manifest.imageIds.$k = Get-DockerImageId ([string]$images[$k])
}
foreach ($k in $environmentSnapshots.Keys) { $manifest.environment.$k = $environmentSnapshots[$k] }
$manifestPath = Join-Path $runtimeRoot 'runtime-manifest.json'
Write-Utf8NoBom $manifestPath (($manifest | ConvertTo-Json -Depth 8) + "`n")
Pass "manifest: $manifestPath"

# ── 10. 설치본 ───────────────────────────────────────────────────────
$desktop = Join-Path $sources.architect 'desktop'
Build-CoLocatedFrontend
Invoke-Checked 'npm.cmd' @('run', 'build') $desktop
Invoke-Checked 'npx.cmd' @('electron-builder') $desktop
$installer = Get-ChildItem (Join-Path $desktop 'out\dist') -Filter 'Robo-Architect-Setup-*.exe' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $installer) { throw 'lite.installer_not_found' }

New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$releaseInstaller = Join-Path $releaseRoot ("Robo-Architect-Setup-$releaseId.exe")
Copy-Item -LiteralPath $installer -Destination $releaseInstaller -Force
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $releaseRoot 'runtime-manifest.json') -Force
$releaseArchive = Join-Path $releaseRoot 'robo-images.tar'
Copy-Item -LiteralPath $imageArchive -Destination $releaseArchive -Force

# ⚠ 중앙 서버 묶음은 **싣지 않는다** — lite 에 중앙 모드가 없다.
@(
  "$((Get-FileHash -Algorithm SHA256 -LiteralPath $releaseInstaller).Hash.ToLowerInvariant())  $(Split-Path $releaseInstaller -Leaf)",
  "$((Get-FileHash -Algorithm SHA256 -LiteralPath $releaseArchive).Hash.ToLowerInvariant())  robo-images.tar"
) -join "`n" | ForEach-Object { Write-Utf8NoBom (Join-Path $releaseRoot 'SHA256SUMS') ($_ + "`n") }

# ── 11. 구성품 목록(SBOM) ────────────────────────────────────────────
if ($SkipSbom) {
  Warn 'SBOM 을 건너뛴다(-SkipSbom). 남에게 주기 전에 반드시 뽑는다:'
  Warn "  python scripts\sbom-release.py `"$releaseRoot`""
} else {
  Info "SBOM 을 뽑는다 (이미지 $($images.Count)장 · 수 분 걸린다)"
  & python (Join-Path $PSScriptRoot 'sbom-release.py') $releaseRoot
  if ($LASTEXITCODE -ne 0) {
    Warn "SBOM 을 못 뽑았다(exit $LASTEXITCODE). 릴리스 자체는 온전하지만 sbom 폴더가 없다."
    Warn "  python scripts\sbom-release.py `"$releaseRoot`""
  } else { Pass "sbom ready: $(Join-Path $releaseRoot 'sbom')" }
}

Pass "lite release ready: $releaseRoot"
Write-Host ""
Write-Host "설치 파일: $releaseInstaller"
Write-Host "부품 묶음: $releaseArchive"
Write-Host ""
Write-Host "깐 뒤 robo-images.tar 을 아래로 옮긴다:"
Write-Host "  $env:APPDATA\robo-architect-desktop\runtime\robo-images.tar"
