<#
  release-deliver.ps1 — 릴리스 한 판을 **깃으로 전달할 모양**으로 가른다.

  왜 가르나. 한 폴더를 그대로 가지에 커밋할 수 없다 —
    · GitHub 은 **파일 하나가 100 MiB** 를 넘으면 push 를 막는다(hard block).
      robo-images.tar 는 1.8 GiB, 설치본 EXE 는 100 MiB 를 조금 넘는다.
    · zip 으로 줄지도 않는다 — 실측 **99.1%**(도커 tar 안의 레이어가 이미 압축이다).
    · Git LFS 로는 들어가지만(파일당 2 GB) 레포에 **영구히** 남고 월 할당(10 GB)을
      먹는다. 한 판 받을 때마다 1.8 GB 다.

  그래서 둘로 가른다.
    가지에 커밋   central-server/ · robo-env.ps1 · runtime-manifest.json ·
                  SHA256SUMS · sbom/            ← 다 합쳐 20 MB 남짓
    릴리스 자산   robo-images.tar · 설치본 EXE   ← 파일당 2 GiB 미만 · 전송량 제한 없음
                  (clone 을 불리지 않는다)

  쓰는 법
      pwsh -File scripts\release-deliver.ps1 -ReleaseId <릴리스ID>
      pwsh -File scripts\release-deliver.ps1 -ReleaseId <릴리스ID> -Branch delivery/<릴리스ID>

  ⚠ 올리는 일은 **이 스크립트가 하지 않는다.** 모양만 만들고, 무엇을 어디에
    올릴지 알려 준다. uengine-oss/robo-workspace 는 **공개 저장소**이므로
    자산을 올리면 누구나 받을 수 있다 — 그 판단은 사람이 한다.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ReleaseId,
  [string]$Branch,
  [string]$ReleasesRoot = (Join-Path $PSScriptRoot '..\_releases'),
  # 자산 한 조각의 상한. GitHub 자산은 2 GiB 미만이어야 한다. 1.8 GiB 로 두어
  # 여유를 남긴다 — 다음 판에서 이미지가 조금 늘면 2 GiB 를 넘기 때문이다.
  [long]$MaxAssetBytes = 1932735283  # 1.8 GiB
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  $m" }
function Pass($m) { Write-Host "  v $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Die($m) { Write-Host ''; Write-Host "막혔다: $m" -ForegroundColor Red; exit 1 }
function Gib($b) { '{0:N2} GiB' -f ($b / 1GB) }
function Mib($b) { '{0:N1} MiB' -f ($b / 1MB) }

$release = Join-Path (Resolve-Path $ReleasesRoot) $ReleaseId
if (-not (Test-Path -LiteralPath $release)) {
  Write-Host '있는 판:' -ForegroundColor Yellow
  Get-ChildItem (Resolve-Path $ReleasesRoot) -Directory | ForEach-Object { Write-Host "    $($_.Name)" }
  Die "그 판이 없다: $release"
}

# ── 1. 온전한지 먼저 본다 ────────────────────────────────────────────────────
#  ⚠ 깨진 판을 전달 모양으로 만들어 올리면, 받는 쪽은 SHA256SUMS 대조에서야
#    안다. 여기서 먼저 재는 편이 싸다.
Write-Host ''
Write-Host "== 1. SHA256SUMS 대조 ==" -ForegroundColor DarkGray
$sumsPath = Join-Path $release 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $sumsPath)) { Die "SHA256SUMS 가 없다: $sumsPath" }
$checked = 0
foreach ($line in Get-Content -LiteralPath $sumsPath) {
  if ($line -notmatch '^([0-9a-f]{64})\s+(.+)$') { continue }
  $want = $Matches[1]; $rel = $Matches[2].Trim()
  $path = Join-Path $release ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $path)) { Die "SHA256SUMS 가 가리키는 파일이 없다: $rel" }
  $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  if ($got -ne $want) { Die "체크섬이 다르다: $rel`n  적힌 값 $want`n  실제   $got" }
  $checked++
}
if ($checked -lt 1) { Die 'SHA256SUMS 에서 대조할 줄을 못 찾았다. 양식이 바뀌었나 본다.' }
Pass "$checked 개 파일 체크섬 일치"

# ── 2. 가지에 담을 작은 몫을 고른다 ──────────────────────────────────────────
#  가지에는 **글과 sbom 만** 올린다. 큰 둘(설치본 EXE · robo-images.tar)은
#  100 MiB 벽에 걸리고, LFS 는 월 10 GB 를 먹으며 레포에 영구히 남는다.
Write-Host ''
Write-Host "== 2. 가른다 ==" -ForegroundColor DarkGray
$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$stage = Join-Path $workspaceRoot "_delivery\$ReleaseId"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
# ⚠ `_delivery/` 는 .gitignore 에 있어야 한다 — 없으면 1.8 GiB 조각이 추적되어
#   굽기의 "작업 트리 0건" 게이트가 멈춘다.
$out = Join-Path $stage 'repo'         # 가지에 담을 것
$assetDir = Join-Path $stage 'assets'  # 보내는 것 · 자산으로 올리는 것
New-Item -ItemType Directory -Force -Path $out, $assetDir | Out-Null

$big = @()
$committed = @()
foreach ($item in Get-ChildItem -LiteralPath $release) {
  $size = if ($item.PSIsContainer) {
    (Get-ChildItem $item.FullName -Recurse -File | Measure-Object Length -Sum).Sum
  } else { $item.Length }
  if ((-not $item.PSIsContainer) -and $size -gt 100MB) {
    $big += [pscustomobject]@{ Name = $item.Name; Size = $size }
  } else {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $out $item.Name) -Recurse -Force
    $committed += [pscustomobject]@{ Name = $item.Name; Size = $size }
  }
}
Info '가지에 담을 것'
foreach ($c in $committed) { Info ("    {0,10}  {1}" -f (Mib $c.Size), $c.Name) }
Info ("    {0,10}  = 합계" -f (Mib (($committed | Measure-Object Size -Sum).Sum)))
Info ''
Info '가지에 담지 못하는 것 (100 MiB 벽)'
foreach ($b in $big) { Info ("    {0,10}  {1}" -f (Gib $b.Size), $b.Name) }

# ── 3. 릴리스 폴더를 **한 묶음**으로 zip 한다 ────────────────────────────────
#  ⚠ 줄이려는 것이 아니다 — 실측 **99.1%**(도커 tar 안의 레이어가 이미 압축).
#    **한 파일로 묶으려는** 것이다. 받는 쪽은 풀면 릴리스 폴더가 그대로 나온다.
#  ⚠ Compress-Archive 를 쓰지 않는다 — 2 GiB 급에서 느리고 메모리를 먹는다.
#    윈도우에 들어 있는 bsdtar(`tar.exe`)가 확장자로 zip 을 만든다.
Write-Host ''
Write-Host "== 3. 릴리스 전체를 zip ==" -ForegroundColor DarkGray
$zipName = "$ReleaseId.zip"
$zipPath = Join-Path $assetDir $zipName
$sw = [Diagnostics.Stopwatch]::StartNew()
Info "묶는다 → $zipName  (몇 분 걸린다)"
& tar.exe -a -c -f $zipPath -C (Split-Path $release -Parent) (Split-Path $release -Leaf)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zipPath)) {
  Die 'zip 을 만들지 못했다 (tar.exe)'
}
$zipSize = (Get-Item $zipPath).Length
$srcSize = (Get-ChildItem -LiteralPath $release -Recurse -File | Measure-Object Length -Sum).Sum
Pass ("{0} → {1}  (압축률 {2:N1}% · {3}초)" -f (Gib $srcSize), (Gib $zipSize),
      (100 * $zipSize / $srcSize), [int]$sw.Elapsed.TotalSeconds)
# 안에 든 것이 맞는지 센다 — 빈 zip 이나 반쪽 zip 이 조용히 지나가지 않게.
$entries = @(& tar.exe -t -f $zipPath 2>$null)
$srcCount = (Get-ChildItem -LiteralPath $release -Recurse -File).Count
Info ("    안에 든 항목 {0}개 (원본 파일 {1}개)" -f $entries.Count, $srcCount)
if ($entries.Count -lt $srcCount) { Die "zip 안의 항목이 원본 파일 수보다 적다 — 반쪽이다" }

# ── 4. 2 GiB 를 넘으면 **그 zip 을** 조각낸다 ────────────────────────────────
#  GitHub 자산은 파일당 2 GiB 미만이다. 넘으면 올릴 수 없고, 가까우면 다음 판에서
#  넘는다. 조각내면 흐름이 끊겼을 때 **그 조각만** 다시 받는다.
$parts = @()
if ($zipSize -gt $MaxAssetBytes) {
  Write-Host ''
  Write-Host "== 4. zip 을 조각낸다 ==" -ForegroundColor DarkGray
  Warn ("zip 이 상한({0} GiB)을 넘는다" -f [math]::Round($MaxAssetBytes / 1GB, 2))
  $partSize = 1073741824  # 1 GiB
  $fs = [IO.File]::OpenRead($zipPath)
  try {
    $buf = New-Object byte[] 8388608
    $idx = 0
    while ($fs.Position -lt $fs.Length) {
      $idx++
      $partPath = Join-Path $assetDir ('{0}.part{1:d3}' -f $zipName, $idx)
      $ps = [IO.File]::Create($partPath)
      try {
        $written = 0L
        while ($written -lt $partSize -and $fs.Position -lt $fs.Length) {
          $n = $fs.Read($buf, 0, [Math]::Min($buf.Length, $partSize - $written))
          if ($n -le 0) { break }
          $ps.Write($buf, 0, $n); $written += $n
        }
      } finally { $ps.Dispose() }
      $parts += Get-Item $partPath
      Info ("    {0}  {1}" -f (Gib (Get-Item $partPath).Length), (Split-Path $partPath -Leaf))
    }
  } finally { $fs.Dispose() }
  Remove-Item -LiteralPath $zipPath -Force   # 조각이 있으면 원본은 둘 필요 없다
  Pass "조각 $($parts.Count)개"
} else {
  Info ''
  Info ("    2 GiB 한도의 {0:N0}% — 쪼개지 않는다" -f (100 * $zipSize / 2GB))
}

# ── 5. 받는 쪽이 대조할 목록과 한 장 ─────────────────────────────────────────
#  ⚠ LF 로 쓴다. CRLF 면 `sha256sum -c` 가 파일명 끝의 CR 까지 이름으로 읽어
#    "No such file" 을 낸다 — 받는 쪽이 제일 먼저 하는 일이 이 대조다.
Write-Host ''
Write-Host "== 5. 체크섬 목록 ==" -ForegroundColor DarkGray
$assetFiles = @(Get-ChildItem -LiteralPath $assetDir -File | Sort-Object Name)
$assetLines = @($assetFiles | ForEach-Object {
  "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())  $($_.Name)"
})
[IO.File]::WriteAllText((Join-Path $out 'ASSETS.sha256'),
                        (($assetLines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Pass "ASSETS.sha256 ($($assetLines.Count)줄) — 가지 쪽에 둔다(받는 쪽이 가지를 먼저 받는다)"

$joinNote = if ($parts.Count) { @"

## 2-A. 조각을 합친다

``````bash
cat $zipName.part* > $zipName
``````
``````powershell
cmd /c copy /b "$(($parts.Name) -join '" + "')" "$zipName"
``````
"@ } else { '' }

$readme = @"
# 받는 쪽 — 이 판을 **한 폴더로** 되돌린다

``````text
릴리스  $ReleaseId
받을 것  $(if ($parts.Count) { "$zipName 의 조각 $($parts.Count)개" } else { $zipName }) ($(Gib $zipSize))
        풀면 릴리스 폴더가 그대로 나온다 — 굽기가 낸 것과 **같다**
여기 것  글과 sbom. 가이드·매니페스트·robo-central.sh 가 들어 있다
``````

## 1. 받는다

Releases 에서 태그 ``$ReleaseId`` 의 자산을 내려받는다.

``````bash
gh release download $ReleaseId --repo uengine-oss/robo-workspace --dir .
``````

## 2. ⚠ 온전한지 **먼저** 본다

``````bash
sha256sum -c ASSETS.sha256
``````
``````powershell
Get-Content ASSETS.sha256 | ForEach-Object {
  `$f = (`$_ -split '\s+')[1]; `$want = (`$_ -split '\s+')[0]
  `$got = (Get-FileHash -Algorithm SHA256 `$f).Hash.ToLowerInvariant()
  '{0,-64} {1}' -f `$f, `$(if (`$got -eq `$want) { 'ok' } else { '**다르다**' })
}
``````
$joinNote
## 3. 푼다

``````bash
unzip -q $zipName          # 리눅스
``````
``````powershell
tar -xf $zipName           # 윈도우 — 들어 있는 tar.exe 가 bsdtar 라 zip 을 읽는다
``````

> ⚠ **리눅스에서 ``tar -xf <zip>`` 은 안 된다.** GNU tar 는 zip 을 못 읽어
> *"This does not look like a tar archive"* 가 난다(2026-10-29 실측).
> ``unzip`` 이 없으면 ``python3 -m zipfile -e $zipName .`` 을 쓴다.

## 4. ⚠ 푼 뒤 **다시 대조한다**

``````bash
cd $ReleaseId
sha256sum -c SHA256SUMS
``````

여덟 줄 모두 ``OK`` 여야 한다. 이 대조가 **앱이 쓸 것과 같은 값**을 본다 —
앱은 ``robo-images.tar`` 를 쓰기 전에 매니페스트의 ``imageArchiveSha256`` 을
확인하고 다르면 거절한다.

## 5. 그다음

``````text
DB 서버(리눅스)   central-server/robo-central.sh 의 [고치는 곳] 둘을 채워 돌린다
                  → docs/가이드/관리자-DB올리기.md
사용자 PC(윈도우) robo-env.ps1 의 [고치는 곳] 을 채워 돌린 뒤 설치본을 깐다
                  → docs/가이드/사용자-설치-가이드.md
``````

> ⓘ **도커 레지스트리가 열려 있다면** 1.8 GiB 를 받지 않아도 된다 —
> 이미지 열 장을 ``docker pull`` 하면 앱이 적재를 건너뛴다.
> ``docs/가이드/납품물-전달.md`` 의 "레지스트리" 절을 본다.
"@
[IO.File]::WriteAllText((Join-Path $out 'README-전달.md'), ($readme -replace "`r`n", "`n"),
                        (New-Object Text.UTF8Encoding $false))
Pass 'README-전달.md'

# ── 6. 다음에 사람이 할 일 ───────────────────────────────────────────────────
Write-Host ''
Write-Host "== 6. 이제 사람이 한다 ==" -ForegroundColor DarkGray
$branchName = if ($Branch) { $Branch } else { "delivery/$ReleaseId" }
$wt = Join-Path (Split-Path $workspaceRoot -Parent) "robo-delivery-$ReleaseId"
Info '① 가지에 커밋한다'
Info ''
Info "    # ⚠ **worktree 로 한다.** 지금 작업 트리에 파일을 복사해 커밋하면,"
Info "    #   굽기의 '작업 트리 0건' 게이트가 다음 굽기에서 멈춘다."
Info "    git -C `"$workspaceRoot`" worktree add -b $branchName `"$wt`""
Info "    mkdir `"$wt\delivery\$ReleaseId`""
Info "    robocopy `"$out`" `"$wt\delivery\$ReleaseId`" /E"
Info "    git -C `"$wt`" add `"delivery/$ReleaseId`""
Info "    git -C `"$wt`" commit -m `"deliver: $ReleaseId — 가지에 담는 몫(자산 제외)`""
Info "    git -C `"$wt`" push -u origin $branchName"
Info "    git -C `"$workspaceRoot`" worktree remove `"$wt`"     # 끝나면 치운다"
Info ''
Info '② 릴리스 자산으로 올린다'
Info ''
Info "    올릴 파일이 모여 있는 곳:  $assetDir"
foreach ($f in Get-ChildItem -LiteralPath $assetDir | Sort-Object Name) {
  Info ("      {0,10}  {1}" -f (Gib $f.Length), $f.Name)
}
Info ''
Info '    (가) 웹 — 저장소 Releases → Draft a new release → 태그를 릴리스 id 로'
Info '         만들고 그 폴더의 파일을 끌어다 놓는다. 자산 한 파일 2 GiB 미만'
Info '    (나) gh  — 이미 깔려 있다(2.103.3). ⚠ gh auth login 은 사람이 직접 한다'
Info "         gh release create $ReleaseId `"$assetDir\*`" --repo uengine-oss/robo-workspace ``"
Info "           --title `"$ReleaseId`" --notes-file `"$(Join-Path $out 'README-전달.md')`""
Write-Host ''
Warn 'uengine-oss/robo-workspace 는 **공개 저장소**다 — 올리면 누구나 받는다.'
Warn '설치본에는 고객 내부 주소(P-GPT 엔드포인트)가 구워져 있다. 비밀은 없지만'
Warn '고객 내부 주소를 공개하는 일이므로, 올릴지는 **사람이 정한다.**'
Write-Host ''
Pass "전달 폴더: $out"
