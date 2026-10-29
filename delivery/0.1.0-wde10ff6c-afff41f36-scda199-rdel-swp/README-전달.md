# 받는 쪽 — 이 판을 **한 폴더로** 되돌린다

```text
릴리스  0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp
받을 것  0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip 의 조각 2개 (1.91 GiB)
        풀면 릴리스 폴더가 그대로 나온다 — 굽기가 낸 것과 **같다**
여기 것  글과 sbom. 가이드·매니페스트·robo-central.sh 가 들어 있다
```

## 1. 받는다

Releases 에서 태그 `0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp` 의 자산을 내려받는다.

```bash
gh release download 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp --repo uengine-oss/robo-workspace --dir .
```

## 2. ⚠ 온전한지 **먼저** 본다

```bash
sha256sum -c ASSETS.sha256
```
```powershell
Get-Content ASSETS.sha256 | ForEach-Object {
  $f = ($_ -split '\s+')[1]; $want = ($_ -split '\s+')[0]
  $got = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLowerInvariant()
  '{0,-64} {1}' -f $f, $(if ($got -eq $want) { 'ok' } else { '**다르다**' })
}
```

## 2-A. 조각을 합친다

```bash
cat 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip.part* > 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip
```
```powershell
cmd /c copy /b "0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip.part001" + "0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip.part002" "0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip"
```
## 3. 푼다

```bash
unzip -q 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip          # 리눅스
```
```powershell
tar -xf 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip           # 윈도우 — 들어 있는 tar.exe 가 bsdtar 라 zip 을 읽는다
```

> ⚠ **리눅스에서 `tar -xf <zip>` 은 안 된다.** GNU tar 는 zip 을 못 읽어
> *"This does not look like a tar archive"* 가 난다(2026-10-29 실측).
> `unzip` 이 없으면 `python3 -m zipfile -e 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp.zip .` 을 쓴다.

## 4. ⚠ 푼 뒤 **다시 대조한다**

```bash
cd 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp
sha256sum -c SHA256SUMS
```

여덟 줄 모두 `OK` 여야 한다. 이 대조가 **앱이 쓸 것과 같은 값**을 본다 —
앱은 `robo-images.tar` 를 쓰기 전에 매니페스트의 `imageArchiveSha256` 을
확인하고 다르면 거절한다.

## 5. 그다음

```text
DB 서버(리눅스)   central-server/robo-central.sh 의 [고치는 곳] 둘을 채워 돌린다
                  → docs/가이드/관리자-DB올리기.md
사용자 PC(윈도우) robo-env.ps1 의 [고치는 곳] 을 채워 돌린 뒤 설치본을 깐다
                  → docs/가이드/사용자-설치-가이드.md
```

> ⓘ **도커 레지스트리가 열려 있다면** 1.8 GiB 를 받지 않아도 된다 —
> 이미지 열 장을 `docker pull` 하면 앱이 적재를 건너뛴다.
> `docs/가이드/납품물-전달.md` 의 "레지스트리" 절을 본다.