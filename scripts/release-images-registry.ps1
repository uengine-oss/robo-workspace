<#
  release-images-registry.ps1 — 릴리스 이미지 열 장을 **레지스트리로 보내고 받는다**.

  왜 이 길인가. `robo-images.tar` 는 1.8 GiB 이고, 깃 가지에는 못 들어간다
  (파일당 100 MiB 벽). 자산으로 올릴 수는 있지만 **판마다 1.8 GiB 를 새로**
  올린다. 레지스트리는 **레이어를 나눠 쓰므로** 다음 판은 바뀐 레이어만 간다.

  그리고 받는 쪽이 이미지를 갖게 되면 **tar 가 아예 필요 없다.**
    · 앱     `ensureImages()` 가 열 장의 image ID 를 매니페스트 `imageIds` 와
             대조해 다 맞으면 `docker.images.reused` 로 tar 를 건너뛴다
    · DB 서버 `robo-central.sh` 가 세 장을 같은 방식으로 보고 `docker load` 를 건너뛴다

  ⚠ tar 를 `docker save` 로 **되만드는 길은 안 된다** — 열 장을 같은 순서로 두 번
    떠도 sha 가 다르다(크기는 같다. 2026-10-29 실측). 앱이 `imageArchiveSha256` 을
    검사하므로 되만든 tar 는 거절된다. 그래서 이미지 자체를 보낸다.

  쓰는 법 — 보내는 쪽
      docker login ghcr.io                     ← ⚠ **사람이 직접** 한다
      pwsh -File scripts\release-images-registry.ps1 -Push `
        -ReleaseDir <릴리스폴더> -Registry ghcr.io/uengine-oss

  쓰는 법 — 받는 쪽 (사용자 PC · 윈도우)
      docker login ghcr.io                     ← 비공개로 올렸을 때만
      pwsh -File release-images-registry.ps1 -Pull `
        -ReleaseDir <받은폴더> -Registry ghcr.io/uengine-oss

  받는 쪽 리눅스(DB 서버)는 이 스크립트가 필요 없다 — 아래가 찍어 주는
  `docker pull`·`docker tag` 두 줄짜리 묶음을 그대로 돌리면 된다(-Pull -Print).

  ⚠ **아직 한 번도 통과시켜 보지 못한 단계가 하나 있다**: push·pull 을 거친 뒤
    image ID 가 **그대로인지**. 태그는 포인터라 유지돼야 하지만, buildkit·
    manifest list 가 끼면 달라질 수 있다. 이 스크립트는 pull 뒤에 **매니페스트와
    대조하고 다르면 멈춘다** — 거기서 걸리면 tar 길로 돌아간다.
#>
[CmdletBinding(DefaultParameterSetName = 'Push')]
param(
  [Parameter(ParameterSetName = 'Push', Mandatory = $true)][switch]$Push,
  [Parameter(ParameterSetName = 'Pull', Mandatory = $true)][switch]$Pull,
  [Parameter(Mandatory = $true)][string]$ReleaseDir,
  [Parameter(Mandatory = $true)][string]$Registry,
  [switch]$Print
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  $m" }
function Pass($m) { Write-Host "  v $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Die($m) { Write-Host ''; Write-Host "막혔다: $m" -ForegroundColor Red; exit 1 }

$root = Resolve-Path -LiteralPath $ReleaseDir
$manifestPath = @(
  (Join-Path $root 'runtime-manifest.json'),
  (Join-Path $root 'central-server\runtime-manifest.json')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $manifestPath) { Die "runtime-manifest.json 이 없다: $root" }

$manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
$names = @($manifest.images.PSObject.Properties.Name)
if ($names.Count -lt 1) { Die '매니페스트에 images 가 없다' }
$reg = $Registry.TrimEnd('/')

# 원래 이름(uengine/ontological-db:<id>) → 레지스트리 이름.
# ⚠ 앱이 보는 이름은 **원래 이름**이다. 받는 쪽은 pull 한 뒤 **반드시 되태그**한다.
function Remote-Ref([string]$originalRef) {
  $leaf = $originalRef.Split('/')[-1]        # name:tag
  return "$reg/$leaf"
}

Write-Host ''
Write-Host "== 릴리스 $($manifest.releaseId) · 이미지 $($names.Count)장 ==" -ForegroundColor DarkGray
Info "레지스트리: $reg"

# ── 찍기만 하는 모드 — 리눅스에서 그대로 붙여 쓸 줄을 낸다 ───────────────────
if ($Print) {
  Write-Host ''
  Info '# 받는 쪽에서 그대로 돌린다 (리눅스·윈도우 공통)'
  foreach ($n in $names) {
    $orig = [string]$manifest.images.$n
    Info "docker pull $(Remote-Ref $orig)"
    Info "docker tag  $(Remote-Ref $orig) $orig"
  }
  Write-Host ''
  Info '# 그다음 열 장이 맞는지 본다 — 앱이 하는 것과 같은 대조다'
  foreach ($n in $names) {
    Info ("docker image inspect --format '{{.Id}}' " + [string]$manifest.images.$n +
          "   # = " + [string]$manifest.imageIds.$n)
  }
  exit 0
}

if ($Push) {
  # ── 1. 열 장이 **그 장인지** 먼저 본다 ────────────────────────────────────
  foreach ($n in $names) {
    $orig = [string]$manifest.images.$n
    $want = [string]$manifest.imageIds.$n
    $got = (& docker image inspect --format '{{.Id}}' $orig 2>$null)
    if ($LASTEXITCODE -ne 0) { $got = $null }
    if ($got -ne $want) {
      Die ("$orig 가 로컬에 없거나 다른 장이다. 올릴 수 없다 — " +
           '그 판을 구운 기계에서 돌리거나 tar 로 먼저 적재한다')
    }
  }
  Pass "열 장 전부 image ID 가 매니페스트와 같다"

  # ── 2. 되태그하고 올린다 ──────────────────────────────────────────────────
  $pushed = @()
  foreach ($n in $names) {
    $orig = [string]$manifest.images.$n
    $remote = Remote-Ref $orig
    & docker tag $orig $remote
    if ($LASTEXITCODE -ne 0) { Die "docker tag 실패: $orig → $remote" }
    Info "push $remote"
    & docker push $remote 2>&1 | Select-Object -Last 1 | ForEach-Object { Info "    $_" }
    if ($LASTEXITCODE -ne 0) {
      Die ("docker push 실패: $remote`n" +
           '  ⚠ `docker login ghcr.io` 를 먼저 한다 — 이 스크립트는 자격을 다루지 않는다. ' +
           'ghcr 은 packages:write 권한이 있는 토큰이 필요하다')
    }
    $pushed += $remote
  }
  Pass "열 장을 올렸다"
  Write-Host ''
  Info '받는 쪽에 알려 줄 것'
  Info "  레지스트리  $reg"
  Info "  릴리스      $($manifest.releaseId)"
  Info '  명령        release-images-registry.ps1 -Pull -ReleaseDir <폴더> -Registry ' + $reg
  Write-Host ''
  Warn '공개 레지스트리에 올렸다면 — analyzer 이미지의 llm/configs/pgpt.yaml 에'
  Warn '사내 AI 게이트웨이 호스트 이름(aigpt.posco.net)이 들어 있다. 자격은 없다.'
  exit 0
}

# ── Pull ─────────────────────────────────────────────────────────────────────
$bad = @()
foreach ($n in $names) {
  $orig = [string]$manifest.images.$n
  $want = [string]$manifest.imageIds.$n
  $remote = Remote-Ref $orig
  Info "pull $remote"
  & docker pull $remote 2>&1 | Select-Object -Last 1 | ForEach-Object { Info "    $_" }
  if ($LASTEXITCODE -ne 0) {
    Die ("docker pull 실패: $remote`n" +
         '  비공개로 올렸으면 `docker login` 을 먼저 한다. 방화벽이 레지스트리를 ' +
         '막고 있으면 이 길은 쓸 수 없다 — tar 길로 간다(docs/가이드/납품물-전달.md)')
  }
  # ⚠ 앱이 보는 이름은 **원래 이름**이다. 되태그하지 않으면 tar 를 찾으러 간다.
  & docker tag $remote $orig
  $got = (& docker image inspect --format '{{.Id}}' $orig 2>$null)
  if ($LASTEXITCODE -ne 0) { $got = $null }
  if ($got -ne $want) { $bad += [pscustomobject]@{ Ref = $orig; Want = $want; Got = $got } }
}
if ($bad.Count) {
  Write-Host ''
  foreach ($b in $bad) {
    Warn "$($b.Ref) — want $($b.Want) / got $(if($b.Got){$b.Got}else{'없다'})"
  }
  Die ("받은 장의 image ID 가 매니페스트와 다르다($($bad.Count)장). " +
       "앱도 같은 대조를 하고 거절하므로 이 길은 **이 레지스트리로는 성립하지 않는다** — " +
       'tar 길로 간다(docs/가이드/납품물-전달.md)')
}
Pass "열 장 전부 image ID 가 매니페스트와 같다 — **tar 가 필요 없다**"
Write-Host ''
Info '다음'
Info '  사용자 PC   설치본을 깐다. 앱이 docker.images.reused 로 적재를 건너뛴다'
Info '  DB 서버     central-server/robo-central.sh 를 돌린다 (세 장이 있으면 건너뛴다)'
