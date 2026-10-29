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

# ── 2. 가지에 커밋할 것 / 자산으로 올릴 것을 가른다 ──────────────────────────
Write-Host ''
Write-Host "== 2. 가른다 ==" -ForegroundColor DarkGray
$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$stage = Join-Path $workspaceRoot "_delivery\$ReleaseId"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
# 둘을 **갈라 둔다.** 섞어 두면 `git add -f` 한 번에 1.8 GiB 조각까지 담겨
# push 가 막힌다. 그리고 `_delivery/` 는 .gitignore 에 있어야 한다 — 없으면
# 굽기의 "작업 트리 0건" 게이트가 이 조각들 때문에 멈춘다.
$out = Join-Path $stage 'repo'      # 가지에 담을 것
$assetDir = Join-Path $stage 'assets'  # 자산으로 올릴 것 — 커밋하지 않는다
New-Item -ItemType Directory -Force -Path $out, $assetDir | Out-Null

$assets = @()
$committed = @()
foreach ($item in Get-ChildItem -LiteralPath $release) {
  $size = if ($item.PSIsContainer) {
    (Get-ChildItem $item.FullName -Recurse -File | Measure-Object Length -Sum).Sum
  } else { $item.Length }
  # 100 MiB 를 넘는 **파일**만 자산으로 뺀다. 폴더(sbom/)는 안쪽 파일이 작으므로 커밋한다.
  if ((-not $item.PSIsContainer) -and $size -gt 100MB) {
    # 쪼갤 필요가 없는 큰 파일도 자산 폴더에 **복사**해 둔다 — 올릴 것이
    # 한 폴더에 모여 있어야 끌어다 놓기가 한 번에 끝난다.
    $assets += [pscustomobject]@{ Name = $item.Name; Path = $item.FullName; Size = $size }
  } else {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $out $item.Name) -Recurse -Force
    $committed += [pscustomobject]@{ Name = $item.Name; Size = $size }
  }
}

Info '가지에 커밋할 것'
foreach ($c in $committed) { Info ("    {0,10}  {1}" -f (Mib $c.Size), $c.Name) }
Info ("    {0,10}  = 합계" -f (Mib (($committed | Measure-Object Size -Sum).Sum)))
Info ''
Info '릴리스 자산으로 올릴 것'
foreach ($a in $assets) {
  $headroom = 100 * $a.Size / 2GB
  Info ("    {0,10}  {1}   (2 GiB 한도의 {2:N0}%)" -f (Gib $a.Size), $a.Name, $headroom)
}

# ── 3. 2 GiB 에 가까운 파일은 쪼갠다 ─────────────────────────────────────────
#  GitHub 자산은 파일당 2 GiB 미만이다. 넘으면 올릴 수 없고, 가까우면 다음 판에서
#  넘는다. 쪼개면 흐름이 끊겼을 때 **그 조각만** 다시 받으면 된다.
$split = @()
foreach ($a in $assets) {
  if ($a.Size -le $MaxAssetBytes) {
    Copy-Item -LiteralPath $a.Path -Destination (Join-Path $assetDir $a.Name) -Force
    continue
  }
  Warn "$($a.Name) 이 상한($([math]::Round($MaxAssetBytes/1GB,2)) GiB)을 넘는다 — 쪼갠다"
  $partSize = 1073741824  # 1 GiB
  $fs = [IO.File]::OpenRead($a.Path)
  try {
    $buf = New-Object byte[] 8388608
    $idx = 0
    while ($fs.Position -lt $fs.Length) {
      $idx++
      $partName = '{0}.part{1:d3}' -f $a.Name, $idx
      $partPath = Join-Path $assetDir $partName
      $ps = [IO.File]::Create($partPath)
      try {
        $written = 0L
        while ($written -lt $partSize -and $fs.Position -lt $fs.Length) {
          $n = $fs.Read($buf, 0, [Math]::Min($buf.Length, $partSize - $written))
          if ($n -le 0) { break }
          $ps.Write($buf, 0, $n); $written += $n
        }
      } finally { $ps.Dispose() }
      $split += [pscustomobject]@{ Of = $a.Name; Name = $partName; Path = $partPath }
      Info ("    {0}  {1}" -f (Gib (Get-Item $partPath).Length), $partName)
    }
  } finally { $fs.Dispose() }
}

# ── 4. 받는 쪽이 대조할 목록 ─────────────────────────────────────────────────
#  ⚠ LF 로 쓴다. CRLF 면 `sha256sum -c` 가 파일명 끝의 CR 까지 이름으로 읽어
#    "No such file" 을 낸다 — 받는 쪽이 제일 먼저 하는 일이 이 대조다.
Write-Host ''
Write-Host "== 3. 자산 체크섬 목록 ==" -ForegroundColor DarkGray
$assetLines = @()
foreach ($a in $assets) {
  $parts = @($split | Where-Object { $_.Of -eq $a.Name })
  # 쪼갠 것은 **조각마다** 적는다. 쪼개지 않은 것은 원본 그대로 — 그 값은
  # SHA256SUMS 에도 이미 있다(합친 파일의 값은 거기서 확인한다).
  if ($parts.Count) {
    foreach ($p in $parts) {
      $assetLines += "$((Get-FileHash -Algorithm SHA256 -LiteralPath $p.Path).Hash.ToLowerInvariant())  $($p.Name)"
    }
  } else {
    $assetLines += "$((Get-FileHash -Algorithm SHA256 -LiteralPath $a.Path).Hash.ToLowerInvariant())  $($a.Name)"
  }
}
#  ⚠ 목록은 **가지 쪽**에 둔다 — 받는 사람은 가지를 먼저 받고, 그걸로 자산을
#    대조한다. 자산 폴더에만 두면 대조할 기준이 자산과 같은 곳에서 온다.
$assetSums = Join-Path $out 'ASSETS.sha256'
[IO.File]::WriteAllText($assetSums, (($assetLines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
Pass "ASSETS.sha256 ($($assetLines.Count)줄)"

# ── 5. 받는 쪽을 위한 한 장 ──────────────────────────────────────────────────
$joinLinux = ''
$joinWin = ''
foreach ($a in $assets) {
  $parts = @($split | Where-Object { $_.Of -eq $a.Name })
  if (-not $parts.Count) { continue }
  $joinLinux += "cat $($a.Name).part* > $($a.Name)`n"
  $joinWin += "cmd /c copy /b `"$(($parts.Name) -join '" + "')`" `"$($a.Name)`"`n"
}
$readme = @"
# 받는 쪽 — 이 판을 **다시 한 폴더로** 만든다

이 폴더(가지에서 받은 것)와 릴리스 자산을 합치면 굽기가 낸 릴리스 폴더와
**같아진다.** 그 뒤는 가이드 그대로다.

``````text
릴리스  $ReleaseId
가지     여기 있는 것 — central-server/ · robo-env.ps1 · runtime-manifest.json
         SHA256SUMS · sbom/
자산     아래 파일들. 이 폴더에 **그대로 내려놓는다**
$(($assetLines | ForEach-Object { '         ' + ($_ -split '\s+')[1] }) -join "`n")
``````

## 1. 자산을 내려받는다

같은 저장소의 **Releases** 에서 태그 ``$ReleaseId`` 를 찾아 자산을 내려받는다.
명령으로 받으려면(gh 가 있을 때):

``````bash
gh release download $ReleaseId --repo uengine-oss/robo-workspace --dir .
``````

## 2. 온전한지 본다 — **먼저 이것부터**

``````bash
sha256sum -c ASSETS.sha256     # 리눅스
``````
``````powershell
# 윈도우 (PowerShell)
Get-Content ASSETS.sha256 | ForEach-Object {
  `$f = (`$_ -split '\s+')[1]
  `$want = (`$_ -split '\s+')[0]
  `$got = (Get-FileHash -Algorithm SHA256 `$f).Hash.ToLowerInvariant()
  '{0,-60} {1}' -f `$f, `$(if (`$got -eq `$want) { 'ok' } else { '**다르다**' })
}
``````
$(if ($joinLinux) { @"

## 3. 쪼갠 조각을 합친다

``````bash
$joinLinux``````
``````powershell
$joinWin``````

합친 뒤 ``SHA256SUMS`` 로 다시 대조한다 — 그 줄이 **합친 파일**의 값이다.
"@ })

## $(if ($joinLinux) { '4' } else { '3' }). 그다음

``````text
DB 서버(리눅스)   central-server/robo-central.sh 의 [고치는 곳] 둘을 채워 돌린다
                  → docs/가이드/관리자-DB올리기.md
사용자 PC(윈도우) robo-env.ps1 의 [고치는 곳] 을 채워 돌린 뒤 설치본을 깐다
                  → docs/가이드/사용자-설치-가이드.md
``````
"@
[IO.File]::WriteAllText((Join-Path $out 'README-전달.md'), ($readme -replace "`r`n", "`n"),
                        (New-Object Text.UTF8Encoding $false))
Pass 'README-전달.md'

# ── 6. 다음에 사람이 할 일 ───────────────────────────────────────────────────
Write-Host ''
Write-Host "== 4. 이제 사람이 한다 ==" -ForegroundColor DarkGray
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
Info '    (나) gh  — winget install GitHub.cli 로 깐 뒤'
Info "         gh release create $ReleaseId `"$assetDir\*`" --repo uengine-oss/robo-workspace ``"
Info "           --title `"$ReleaseId`" --notes-file `"$(Join-Path $out 'README-전달.md')`""
Write-Host ''
Warn 'uengine-oss/robo-workspace 는 **공개 저장소**다 — 올리면 누구나 받는다.'
Warn '설치본에는 고객 내부 주소(P-GPT 엔드포인트)가 구워져 있다. 비밀은 없지만'
Warn '고객 내부 주소를 공개하는 일이므로, 올릴지는 **사람이 정한다.**'
Write-Host ''
Pass "전달 폴더: $out"
