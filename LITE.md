# `lite-p` — lite 판은 무엇이고 어떻게 굽나

```text
이 가지가 들고 있는 것   ① architect 핀을 lite 가지로  ② lite 전용 굽기 스크립트
                        ③ 이 문서
이 가지가 **아닌** 것    enterprise 납품(`enterprise-custom-p`)과 **섞이지 않는다**
굽는 명령               `.\robo-lite.cmd`        (공용 `robo.cmd release` 가 아니다)
```

> **공용 `robo.ps1` 은 이 줄기 때문에 바뀌지 않는다.** `robo-lite.ps1` 은 그 파일을
> **읽기만** 하고(dot-source) 공용 release 흐름은 호출하지 않는다. enterprise
> 납품 굽기는 이 가지가 있든 없든 글자 하나 달라지지 않는다.

---

## 0. lite 는 무엇이 다른가 — **실측** (2026-10-29)

```text
서비스 **일곱**   graph-db · graph-bolt · fabric · catalog · analyzer · parser · gateway
없는 것 셋        **authority**(계정·프로젝트 게이트웨이) · **pdf2bpmn**(PDF→BPMN) ·
                 **wireframe**(화면 생성, open-pencil)
```

### ⚠ 로그인이 **아예 없다**

```text
api/features/auth      git 추적 **0파일**  (enterprise 9)
                       ⓘ 폴더는 보일 수 있다 — enterprise 를 체크아웃했던 작업
                         트리에 `.pyc` 가 남는다(무시 목록에 있어 가지를 바꿔도
                         안 지워진다). **소스가 없으므로 import 되지 않는다**
LoginView.vue          **0개**             (enterprise 1)
AUTH_ENFORCE 참조      **0파일**           (enterprise 6)
SWP_ 참조              **0파일**           (enterprise 4)
⇒ 앱을 열면 **바로 화면**이다. 사용자 표·권한·SSO·승인제가 없다
⇒ 그래서 매니페스트의 자세 칸도 **authEnforced: false · authProvider: none** 으로
  굽는다 — 그것이 사실이기 때문이다. true 로 적으면 거짓 기록이 된다
```

### ⚠ 외부 LLM 은 **쓴다** — 키가 필요하다

```text
`OPENAI_` **2파일** · `openai`(대소무관) **22파일** · `LLM_` **11파일**
  ⓘ 세는 패턴을 적어 둔다 — 패턴이 다르면 숫자가 달라진다(처음에 이 줄을
    "12파일" 로 적었다가 다시 세서 고쳤다)
⇒ 적재(문서 → 설계)와 탐색이 LLM 으로 돌아간다. **키가 없으면 그 기능이 실패한다**
  (앱은 뜨고 화면도 열린다 — 실패는 **쓸 때** 나온다)
⇒ 키는 설치본에 굽지 않는다. 깔고 나서 **Windows 환경변수**로 넣는다(§3)
```

### 혼자 쓰는 구성뿐이다 (bundled)

```text
lite 저장소에는 중앙 모드 파일이 **아예 없다** —
  compose.remote-graph.yml · compose.central-db.yml ·
  central-authority.env.example · CENTRAL-SERVER.md  전부 없음
⇒ **DB 를 자기 PC 에 띄운다**(graph-db · graph-bolt 가 컨테이너 일곱에 든 이유).
  관리자가 세운 서버가 **필요 없다** — 개인에게는 이게 장점이다
⇒ 설계 데이터는 이 PC 의 도커 볼륨에 있다. 백업은 그 볼륨을 뜬다
```

---

## 1. 굽는다 — **세 줄**

```powershell
cd <robo-workspace>
git checkout lite-p
.\robo-lite.cmd
```

```text
⚠ `.env` 에 **ROBO_RELEASE_VARIANT=lite** 가 있어야 한다. 비우면 스크립트가
   거절한다 — 비운 채 구우면 enterprise 판과 **같은 릴리스 id** 가 나와
   `_releases` 폴더와 **도커 태그**를 덮어쓴다
⚠ 저장소 전부 **작업 트리 0건**이어야 한다(untracked 포함). 새 파일 하나만
   있어도 선다 — 그게 "굽는 내용이 커밋된 것과 같다" 는 보장이다
걸리는 시간  약 20~25분
결과         `_releases\0.1.0-w…-a…-s…-rint-none-**lite**\`
               Robo-Architect-Setup-<id>.exe
               robo-images.tar          (이미지 **일곱**)
               runtime-manifest.json
               SHA256SUMS               ← **두 줄**(enterprise 는 일곱)
               sbom\                    구성품 목록
```

> **enterprise 판과 폴더가 안 섞인다.** 릴리스 id 꼬리의 `-lite` 가 폴더·설치
> 파일·**도커 태그**를 한꺼번에 가른다. 폴더 이름만 손으로 바꾸는 길은 쓰지
> 않았다 — 이미지 태그도 릴리스 id 라서, 폴더만 바꾸면 "이 폴더 = 그 태그" 가
> 깨진다.

---

## 2. 개인 사용자가 깐다

받을 파일은 **셋**이다. 릴리스 폴더에서 그대로 가져간다.

```text
Robo-Architect-Setup-<id>.exe    약 100 MB
robo-images.tar                  약 1.5 GB (이미지 일곱)
SHA256SUMS                       두 줄
```

### 미리 있어야 하는 것

```text
Windows 10/11 (64비트)
Docker Desktop (WSL2) — **켜져 있어야 한다**
디스크 여유 20GB · 메모리 16GB 권장
⇒ git·Node·Python·Java 는 **필요 없다.** 설치본 안에 든다
```

### ① 파일이 온전한지

```powershell
cd <받은 폴더>
Get-Content .\SHA256SUMS
Get-ChildItem .\Robo-Architect-Setup-*.exe, .\robo-images.tar |
  ForEach-Object { "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 $_).Hash.ToLower(), $_.Name }
```

위아래 **두 줄이 짝**을 이뤄야 한다. 다르면 옮기다 깨진 것이다 — 다시 받는다.

### ② AI 키를 넣는다 — **이 판에서 넣을 값은 이것뿐이다**

```powershell
foreach ($n in 'OPENAI_API_KEY','LLM_API_KEY','ROBO_LLM_API_KEY',
               'ROBO_EMBED_API_KEY','ROBO_SEARCH_LLM_API_KEY') {
  [Environment]::SetEnvironmentVariable($n, '<발급받은 키>', 'User')
}
```

```text
⚠ 이름이 다섯인 이유: 서비스마다 읽는 이름이 다르다. **같은 값**을 넣는다
⚠ 넣고 **로그아웃·재로그인**한다. Windows 는 환경변수를 **로그인할 때** 읽는다
ⓘ 로그인 기능이 없으니 계정·비밀번호·DB 접속값은 **넣을 것이 없다**
   (enterprise 가이드의 §3 열일곱 개 중 이 다섯만 해당한다)
```

**키가 살아 있는지**는 값을 찍지 않고 응답 코드로 본다:

```powershell
$v = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY','User')
try {
  (Invoke-WebRequest -Uri 'https://api.openai.com/v1/embeddings' -Method Post `
     -Headers @{ Authorization = "Bearer $v" } -ContentType 'application/json' `
     -Body '{"model":"text-embedding-3-small","input":"x"}' `
     -TimeoutSec 25 -UseBasicParsing).StatusCode
} catch { "실패 ($($_.Exception.Response.StatusCode.value__))" }
```

`200` 이어야 한다. `401` 은 키가 틀렸거나 폐기된 것이고, `429` 는 한도다.

### ③ 설치한다

```powershell
.\Robo-Architect-Setup-<id>.exe
```

관리자 권한은 필요 없다(내 계정에만 깔린다).

> ⚠ **마지막 화면의 "실행" 체크는 끈다.** 설치 프로그램에서 띄운 앱은 그
> 프로그램이 **시작될 때 굳은 환경**을 물려받아, ②에서 넣은 키가 보이지 않는다.

### ④ 부품 묶음을 옮긴다

```powershell
$dst = "$env:APPDATA\robo-architect-desktop\runtime"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\robo-images.tar -Destination $dst -Force
Get-Item "$dst\robo-images.tar" | Select-Object @{n='GB';e={[math]::Round($_.Length/1GB,2)}}
```

**이 단계를 빼먹으면 앱이 "이미지 묶음이 없습니다" 로 멈춘다.**

### ⑤ 바탕화면 아이콘으로 띄운다

```text
처음 한 번은 **4~5분**. 부품 묶음을 풀어 도커에 넣는 시간이다
두 번째부터는 1분 안에 뜬다
⚠ 설치 프로그램에서 띄우지 않는다(위 ③의 이유). **아이콘**으로 띄운다
```

확인:

```powershell
docker ps --filter "label=com.docker.compose.project=robo-architect-desktop" --format "{{.Names}}  {{.Status}}"
```

**일곱 줄**이 나오고 전부 `healthy` 여야 한다 — `graph-db`·`graph-bolt` 가
**여기 보이는 것이 정상**이다(enterprise 중앙 구성과 반대다. lite 는 DB 를
자기 PC 에 띄운다).

---

## 3. 잘 됐는지

```text
1  컨테이너 일곱이 healthy
2  앱을 열면 **바로 화면**이 뜬다 (로그인을 묻지 않는다 — 그게 정상이다)
3  프로젝트를 만든다 → 목록에 보인다
4  문서를 올린다 → 진행이 보이고 설계가 생긴다   ← **여기서 AI 키가 쓰인다**
5  앱을 껐다 켠다 → **만든 것이 그대로 있다**(볼륨에 남는다)
```

4번이 실패하면 거의 AI 키다 — §2 ②의 확인을 다시 한다.

---

## 4. 백업 · 지우기

```text
설계가 있는 곳   이 PC 의 도커 볼륨 **robo-architect-desktop_graph_data**
                ⚠ enterprise 중앙 구성에서는 이 볼륨이 **아예 생기지 않는다**.
                  lite 는 반대다 — **여기에 전부 있다**
함께 떠야 하는 것  `%APPDATA%\robo-architect-desktop\` 통째로
                  (secrets\ 와 그것을 푸는 열쇠 `Local State` 가 같이 있어야 한다.
                   한쪽만 백업하면 복구되지 않는다)
```

```powershell
$B = "D:\robo-lite-backup-$(Get-Date -Format yyyyMMdd)"
New-Item -ItemType Directory -Force -Path "$B\volumes" | Out-Null
docker volume ls --format '{{.Name}}' | Where-Object { $_ -like 'robo-architect-desktop_*' } |
  ForEach-Object { docker run --rm -v "${_}:/from" -v "${B}\volumes:/to" alpine:3.19 tar -czf "/to/$_.tgz" -C /from . }
Copy-Item "$env:APPDATA\robo-architect-desktop" -Destination "$B\appdata" -Recurse -Force -Exclude 'robo-images.tar'
```

> 앱을 **끄고** 한다. 켜진 채로 뜨면 데이터베이스가 쓰는 중일 수 있다.

지우기: `"$env:LOCALAPPDATA\Programs\Robo-Architect\Uninstall Robo-Architect.exe"`.
**프로그램을 지워도 데이터는 남는다** — 볼륨과 `%APPDATA%\robo-architect-desktop`
을 따로 지워야 하고, **되돌릴 수 없다.**

---

## 5. 이 가지를 **최신으로 유지하는 법**

```text
lite 는 **main 에서 뗀 가지**다. enterprise(`enterprise-custom-p`)와 섞지 않는다.
지금까지 lite 에 따로 넣은 것 (2026-10-29):
  엔진 호환 고침 — 적용되는 것만
    ✔ 탐색 실패를 로그에도 남긴다            (4f45ea2 중 적용 가능한 부분)
    ✔ ReadModel↔Event CQRS 사슬 (ISS-58)     (38461ae 그대로)
    ✘ `_id` bigint 지문 질의 (587cbb7)       — `analysis_binding.py` 가 lite 에 **없다**
    ✘ `save_rule_contexts` 질의 (4f45ea2)    — 그 함수가 lite 에 **없다**
  ✔ `.gitignore` 에 `templates/`             — 없으면 굽기가 막힌다
  ✔ 매니페스트 템플릿에 자리 다섯 + `source` 에 ontological·templates
⚠ enterprise 에서 고침을 가져올 때는 **그 파일이 lite 에 있는지 먼저 본다.**
  없는 기능의 고침을 체리픽하면 **반쪽 기능이 들어온다.**
```

### 이 가지에 남아 있는 **enterprise 시대 파일** — 일부러 둔 것들

```text
docker/mindsdb-trimmed/   한 파일(Dockerfile). `robo.ps1` 주석이 **"되돌릴 때
                          필요한 근거"** 로 남긴다고 적어 뒀다. 실행하는 코드는
                          없다(주석 참조뿐). 지우면 그 결정과 어긋난다
specs/ 22파일              workspace 도구 자신의 이력이다. **기록은 지우지 않는다**
tests/ 11파일              ⚠ **lite 에서 그대로 통하지 않는다** — 아래
release-environment.json   공용 계약이다. lite 도 **쓴다**(환경 스냅샷) — 둔다
scripts/sbom-*.py          lite 도 **쓴다**(`robo-lite.ps1` 이 부른다) — 둔다
⇒ 지운 것은 `DELIVERY-POSCO.md` 하나다 — `enterprise-delivery-p` 가지 설명이고
  lite 와 상관이 없으며 내용도 낡았다(열린 PR #1 을 전제한다)
```

### ⚠ workspace 테스트는 lite 에서 **그대로 통하지 않는다**

```text
`tests/environment-contract.ps1` 은 architect 쪽에서 이런 파일을 **요구한다** —
  desktop\runtime\compose.central-db.yml   ← lite 에 **없다**
  desktop\runtime\compose.remote-graph.yml ← lite 에 **없다**
  그리고 매니페스트 schemaVersion 이 앱의 값과 같은지 본다(lite 는 **3**)
⇒ 이 가지에서 그 테스트를 돌리면 **실패한다.** 그것이 정상이다 —
  그 검사들은 **중앙 모드가 있는 판**을 위한 것이다
실측 (2026-10-29 · lite-p 에서 돌렸다 — 적어 두고 확인했다)
  environment-catalog   **통과** (194 template keys)  ← 이건 lite 에서도 유효하다
  environment-contract  **실패** — 이 문구로 선다:
      Electron release input is missing: desktop\runtime\compose.central-db.yml
  ⇒ 이 문구가 나오면 **고장이 아니다.** 다른 문구로 실패하면 그건 봐야 한다
⇒ lite 에서 믿을 수 있는 검사는 **굽기 자신**이다. `robo-lite.ps1` 이
  매니페스트와 이미지 집합을 **양방향으로** 대조하고(공용에 없는 검사다),
  환경 계약 검사(`Check-ReleaseEnvironment`)도 그대로 돈다
⚠ **"테스트가 빨간 채로 방치" 를 만들지 않으려고 여기 적는다.** 2026-10-29 에
  enterprise 쪽에서 바로 그 일을 겪었다 — mindsdb 를 걷은 뒤 계약 테스트가
  **5일 넘게** 빨간 채였고 아무도 몰랐다(부르는 자동 경로가 없었다)
```
