# 관리자 — **DB 를 올린다**

```text
관리자가 더 하는 일   DB 컨테이너 둘을 올리고 접속값을 만든다. **그것뿐이다.**
그다음              사용자와 **똑같이** `사용자-설치-가이드.md` 를 따라 AP 를 띄운다
한 번만             DB 는 한 곳에 한 번 올린다. 사용자가 늘어도 다시 하지 않는다
전제                릴리스 폴더를 받았다 · Docker 가 있다
```

## 이 가이드가 남기는 것 — 한 장

| 어디에 | 무엇이 | 얼마나 |
|---|---|---|
| `C:\robo-central\` (또는 서버의 `central-server/`) | 작업 폴더 — compose · 매니페스트 · README | 7개 파일 |
| 같은 폴더 | `.env` · `central-authority.env` — **비밀이 여기 있다** | 9줄 · 7줄 |
| 같은 폴더 | `pc-central-setup.ps1` — 다른 PC 에 줄 접속값 | 7줄 |
| Docker | 이미지 **10개** · 네트워크 1 · 볼륨 `..._graph_data` 1 | 1.95GB |
| Docker | 컨테이너 둘 — `graph-db`(5432) · `graph-bolt`(7687) | |
| DB 안 | 역할 둘 · 표 셋 · **최초 관리자 한 명** | |
| Windows | 사용자 환경변수 다섯 (내 PC 에 올렸을 때) | |
| 방화벽 | 인바운드 둘 (다른 PC 를 붙일 때만) | |

**지우면 되돌릴 수 없는 것**은 볼륨 `..._graph_data` 와 설정 파일 둘이다.
`down` 할 때 **`-v` 를 붙이지 않는다.**

---

## 어디에 올리나 — **한 번만 고른다**

```text
Ⓐ 공용 서버      사내망 서버에 올린다. 납품 구성이다.        → 각 단계의 **(서버)** 블록
Ⓑ 내 PC         서버를 아직 못 쓸 때. 시험·검증용이다.      → 각 단계의 **(내 PC)** 블록
```

**고른 쪽 블록만 따라간다.** (서버)는 전부 **bash**, (내 PC)는 전부 **PowerShell** 이다.
섞어 붙이면 `sha256sum 용어가 인식되지 않습니다` 같은 오류가 난다.

---

## 내가 정하는 값은 **둘**뿐이다 — 나중에 고칠 것은 **하나**

```text
내가 고른다      $SERVER_IP    DB 를 공개할 사내망 IP      → 3번
                $ADMIN_EMPNO  최초 관리자의 사번          → 3번
기계가 만든다     비밀 다섯 (GRAPH_PW · AUTH_RT_PW · OPER_PW ·
                ROLE_SECRET · JWT_SECRET)                → 4번. 사람이 고르지 않는다
```

### ⚠ 나중에 고치게 되는 것은 **`SERVER_IP` 하나다**

DHCP 면 주소가 바뀐다. 그때 **세 자리를 함께** 고친다 — 하나라도 빠뜨리면
**오류 없이** 안 된다.

```text
① 작업 폴더의 `.env`     ROBO_GRAPH_BIND · ROBO_AUTHORITY_BIND   (두 줄)
② 컨테이너 다시 만들기   docker compose up -d --force-recreate graph-db graph-bolt
③ 각 PC 의 접속값        ROBO_GRAPH_HOST
                        (사용자 가이드 §3 의 `robo-env.ps1` → $GRAPH_HOST)
```

> **증상이 조용하다.** 주소가 없어지면 컨테이너는 `Up (healthy)` 인 채로 떠 있고,
> `docker ps` 의 **Ports 칸만 빈다.** 사용자 쪽에는 `fabric is unhealthy` 로
> 엉뚱하게 나타난다. 그러니 **Ports 칸을 먼저 본다.**

> ⚠ **순서가 있다.** 주소를 고치는 일이 **사용자 PC 의 앱보다 먼저**다.
> 환경변수는 컨테이너가 **뜰 때** 박히므로, 앱이 먼저 뜨면 그 컨테이너는 옛
> 주소를 쥔 채 `unhealthy` 가 된다. 고친 뒤에는 **앱을 껐다가 바탕화면
> 아이콘으로 다시 띄운다** — 중앙만 다시 올려서는 안 풀린다.

> 애초에 **고정 IP(정적 할당 또는 DHCP 예약)로 받는 것**이 이 일을 없앤다.

---

# 1. 남은 환경변수를 지운다

> **왜 먼저 하나.** `docker compose` 는 **셸 환경변수를 `.env` 파일보다 먼저** 읽는다.
> 지난 설치의 `ROBO_GRAPH_PASSWORD` 가 남아 있으면 DB 가 **그 옛 비밀번호로
> 초기화되고**, 5번이 "DB 연결·스키마·운영 권한을 확인하세요" 로 실패한다.
> 2026-10-14 에 실제로 그렇게 막혔다.

### (내 PC)

```powershell
foreach ($n in 'ROBO_GRAPH_MODE','ROBO_GRAPH_HOST','ROBO_GRAPH_PASSWORD',
               'ROBO_GRAPH_PG_PORT','ROBO_GRAPH_BOLT_PORT','ROBO_GRAPH_USER',
               'ROBO_GRAPH_DESIGN','ROBO_GRAPH_ANALYSIS','ROBO_GRAPH_BIND',
               'ROBO_AUTHORITY_URL','ROBO_INGESTION_URL') {
  [Environment]::SetEnvironmentVariable($n, $null, 'User')
}
(Get-Item 'HKCU:\Environment').GetValueNames() | Where-Object { $_ -like 'ROBO_GRAPH*' }
```

마지막 줄이 **아무것도 출력하지 않아야** 한다. 그리고 **이 창을 닫고 새로 연다** —
닫지 않으면 지운 값이 이 창에 그대로 남는다.

### (서버)

```bash
env | grep -E '^ROBO_GRAPH|^ROBO_AUTHORITY' || echo '남은 것 없음'
```

나오는 것이 있으면 그 줄을 `~/.bashrc`·`/etc/environment` 에서 지우고 다시 로그인한다.

---

```text
[1번이 남기는 것]
만든다   없음 — **지우기만** 한다
확인     마지막 줄이 아무것도 출력하지 않는다
```

# 2. 이미지를 올린다

### (내 PC)

```powershell
# ⚠ 릴리스 ID 는 굽기가 정한다. 아래로 **그때 값**을 확인해 넣는다 —
#   Get-ChildItem C:\Users\YSW\Desktop\robo-workspace\_releases -Directory | Sort-Object LastWriteTime
$RELID = "<릴리스ID>"   # 예: 0.1.0-w33e037e6-aa63dad94-s245d10-rint-none
$REL   = "C:\Users\YSW\Desktop\robo-workspace\_releases\$RELID"
# 자리표시자를 안 바꿨거나 엉뚱한 판을 적으면 **여기서 멈춘다.**
# 옛 판 폴더가 남아 있어도 조용히 지나가지 않는다 — 그게 10-22 에 걸린 자리다.
if (-not (Test-Path -LiteralPath "$REL\central-server")) { throw "릴리스 폴더가 없다: $REL" }
$WORK = "C:\robo-central"
New-Item -ItemType Directory -Force -Path $WORK | Out-Null
Copy-Item "$REL\central-server\*" $WORK -Force
Copy-Item "$REL\runtime-manifest.json" $WORK -Force
docker load --input "$REL\robo-images.tar"
Set-Location $WORK
```

| 바꿀 값 | 무엇 |
|---|---|
| `$RELID` | **릴리스 id** — 굽기가 정한 폴더 이름. 위 주석의 목록 명령으로 그때 값을 읽는다 |

### (서버) — 먼저 PC 에서 보낸다

```powershell
# $REL 은 위 (내 PC) 칸에서 정한 값이다. 창을 새로 열었으면 그 네 줄을 먼저 다시 돌린다.
scp -r "$REL" ysw@10.10.0.5:/tmp/robo-release
```

| 바꿀 값 | 무엇 |
|---|---|
| `$REL` | 위 **(내 PC)** 칸에서 정한 값을 그대로 쓴다. 창을 새로 열었으면 그 네 줄을 먼저 다시 돌린다 |
| `ysw@10.10.0.5` | **서버 계정@서버 IP**. 그대로 두고 실행하면 `Could not resolve hostname` 이 난다 |

SSH 가 막혀 있으면 USB 로 폴더를 **통째로** 옮긴다. 그다음 서버에서:

```bash
cd /tmp/robo-release
sha256sum -c SHA256SUMS
docker load --input robo-images.tar
cd central-server
cp ../runtime-manifest.json .
docker compose version
```

| 보는 것 | 기준 |
|---|---|
| `sha256sum -c` | 줄마다 **OK**. 하나라도 FAILED 면 옮기다 깨진 것이다 |
| `Loaded image:` | **11줄** |
| `docker compose version` | **v2** 여야 한다. 이 compose 파일은 `--wait` 를 쓴다 |

---

```text
[2번이 남기는 것]
만든다   C:\robo-central\                     작업 폴더
           compose.yml                    125줄   DB·Bolt·Authority 정의
           central-authority.env.example   27줄   채울 양식
           README.md                       76줄   서버 쪽 원문
           runtime-manifest.json           94줄   이미지 태그·id 의 권위
         Docker 이미지                    **10개** (태그에 릴리스 id 가 박혀 있다)
화면에    Loaded image: ... × 11
```

# 3. 값을 정한다 — **두 줄**

### (내 PC)

```powershell
$SERVER_IP   = '192.168.219.185'
$ADMIN_EMPNO = 'DEV-ADMIN'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } |
  Select-Object IPAddress, InterfaceAlias | Format-Table -AutoSize
```

### (서버)

```bash
SERVER_IP=10.10.0.5
ADMIN_EMPNO=M123456
hostname -I
sudo ss -lntp | grep -E ':(5432|7687)\b' || echo '두 포트 비어 있음'
```

| 바꿀 값 | 무엇 | 어떻게 정하나 |
|---|---|---|
| `SERVER_IP` | DB 를 공개할 **사내망/LAN 주소**. **IP 로 받습니다**(호스트 이름이 아니라) — 2026-10-15 결정. ⚠ 그러므로 **고정 IP 여야 합니다**(정적 할당 또는 DHCP 예약). 주소가 바뀌면 컨테이너가 **없는 IP 에 묶인 채 healthy 로 떠 있고** 사용자 PC 는 `fabric is unhealthy` 로 앱이 안 뜹니다 — 원인을 찾기 어렵습니다(done12 §227). 바뀌었다면 ① 이 파일의 `ROBO_GRAPH_BIND`·`ROBO_AUTHORITY_BIND` ② `docker compose up -d --force-recreate graph-db graph-bolt` ③ 각 PC 의 `ROBO_GRAPH_HOST`(사용자 가이드 §3 의 `robo-env.ps1`) — 셋을 모두 고칩니다 | 위 명령에서 "이더넷"·"Wi-Fi"(내 PC) 또는 `hostname -I`(서버) 의 주소. **`vEthernet (WSL)` 주소는 쓰지 않는다** — 다른 PC 가 못 닿는다. `localhost`·`127.0.0.1`·`0.0.0.0` 도 안 된다. 같은 값이 앱 컨테이너 7개에도 들어가고, Bolt 는 평문 인증이다 |
| `ADMIN_EMPNO` | 최초 관리자의 **사번(uid)** | 시험이면 `DEV-ADMIN` — 그러면 앱에서 `admin`/`admin` 으로 들어간다. 납품이면 조직이 정한 실제 사번 |

> **⚠ 그 서버에 msa-ez platform 이 이미 돌고 있다.** 5432 가 부딪히는지는
> **어느 구성이냐**에 달렸다 — 실제로 재서 확인한 것은 이렇다(v1.0.30).
>
> ```text
> 통합 구성      docker-compose.yml          postgres 를 **127.0.0.1:5432** 에 묶는다
>                → 우리는 <SERVER_IP>:5432 에 묶으므로 **부딪히지 않는다.**
>                  내릴 필요 없다
> 분리 DB 서버   docker-compose.split.db.yml postgres 를 **5432:5432**(모든 주소)
>                → **부딪힌다**
> ```
>
> **부딪힐 때 msa-ez 를 내리지 않는다** — 그쪽이 쓰고 있는 플랫폼이다.
> 우리 포트를 옮긴다. `compose.yml` 이 그 자리를 열어 두었다:
>
> ```text
> ${ROBO_GRAPH_PG_PORT:-5432}   ·   ${ROBO_GRAPH_BOLT_PORT:-7687}
> ```
>
> 작업 폴더 `.env` 에 `ROBO_GRAPH_PG_PORT=55432` 처럼 적고 올린다.
> ⚠ **그러면 각 PC 에도 같은 값을 넣어야 한다.** 그런데 지금 `robo-env.ps1` 의
> `[고치는 곳]` 에는 **포트 자리가 없다**(지우기·확인 목록에만 있다). 포트를
> 옮기기로 하면 그 자리를 먼저 만들어야 한다 — 안 그러면 값을 손으로 넣게 되고,
> 다음에 `-Clear` 를 돌릴 때 **조용히 지워진다.**
>
> 내리기로 했다면 **`-v` 를 붙이지 않는다**(볼륨까지 지워 그 데이터가 사라진다).
>
> ```bash
> docker compose -f docker-compose.split.db.yml down
> docker volume ls | grep msaez
> ```

---

```text
[3번이 남기는 것]
만든다   없음 — 이 창의 **셸 변수 둘**뿐이다 ($SERVER_IP · $ADMIN_EMPNO)
         창을 닫으면 사라진다. 4번까지 같은 창에서 이어 간다
```

# 4. 설정 파일 둘을 만든다 — **바꿀 값 없음**

### (내 PC)

```powershell
function New-B64 { $b = New-Object byte[] 48
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  [Convert]::ToBase64String($b) }
function New-Hex { $b = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ($b | ForEach-Object { $_.ToString('x2') }) -join '' }

$rel         = (Get-Content .\runtime-manifest.json -Raw | ConvertFrom-Json).releaseId
$ROLE_SECRET = New-B64 ; $JWT_SECRET = New-B64
$GRAPH_PW    = New-Hex ; $AUTH_RT_PW = New-Hex ; $OPER_PW = New-Hex

@"
ROBO_IMAGE_GRAPH_DB=uengine/ontological-db:$rel
ROBO_IMAGE_GRAPH_BOLT=uengine/ontological-bolt:$rel
ROBO_IMAGE_AUTHORITY=uengine/robo-authority:$rel
ROBO_GRAPH_USER=robo
ROBO_GRAPH_PASSWORD=$GRAPH_PW
ROBO_GRAPH_DESIGN=robo
ROBO_GRAPH_ANALYSIS=analyzer_run
ROBO_GRAPH_BIND=$SERVER_IP
ROBO_AUTHORITY_BIND=$SERVER_IP
"@ | Set-Content -Encoding ascii .\.env

@"
AUTH_PROVIDER=none
AUTH_ENFORCE=true
AUTH_DEV_LOGIN_ENABLED=false
AUTH_JWT_SECRET=$JWT_SECRET
AUTH_ROLE_SECRET=$ROLE_SECRET
OG_PG_DSN=postgresql://robo_authority:$AUTH_RT_PW@graph-db:5432/robo
ROBO_PROJECT_OPERATOR_DSN=postgresql://robo_operator:$OPER_PW@graph-db:5432/robo
"@ | Set-Content -Encoding ascii .\central-authority.env

icacls .\.env /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
icacls .\central-authority.env /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
"릴리스 $rel · 설정 파일 둘 작성 완료"
```

### (서버)

```bash
umask 077
REL=$(sed -n 's/.*"releaseId": *"\([^"]*\)".*/\1/p' runtime-manifest.json | head -1)
ROLE_SECRET=$(openssl rand -base64 48 | tr -d '\n')
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
GRAPH_PW=$(openssl rand -hex 32); AUTH_RT_PW=$(openssl rand -hex 32); OPER_PW=$(openssl rand -hex 32)

cat > .env <<EOF
ROBO_IMAGE_GRAPH_DB=uengine/ontological-db:$REL
ROBO_IMAGE_GRAPH_BOLT=uengine/ontological-bolt:$REL
ROBO_IMAGE_AUTHORITY=uengine/robo-authority:$REL
ROBO_GRAPH_USER=robo
ROBO_GRAPH_PASSWORD=$GRAPH_PW
ROBO_GRAPH_DESIGN=robo
ROBO_GRAPH_ANALYSIS=analyzer_run
ROBO_GRAPH_BIND=$SERVER_IP
ROBO_AUTHORITY_BIND=$SERVER_IP
EOF

cat > central-authority.env <<EOF
AUTH_PROVIDER=none
AUTH_ENFORCE=true
AUTH_DEV_LOGIN_ENABLED=false
AUTH_JWT_SECRET=$JWT_SECRET
AUTH_ROLE_SECRET=$ROLE_SECRET
OG_PG_DSN=postgresql://robo_authority:$AUTH_RT_PW@graph-db:5432/robo
ROBO_PROJECT_OPERATOR_DSN=postgresql://robo_operator:$OPER_PW@graph-db:5432/robo
EOF

chmod 600 .env central-authority.env
echo "릴리스 $REL · 설정 파일 둘 작성 완료"
```

> **이 창(셸)을 닫지 않는다.** `GRAPH_PW` · `ROLE_SECRET` · `JWT_SECRET` 은 여기에만
> 있고 5·6번에서 쓴다. 닫았으면 두 `.env` 파일에서 다시 읽는다.

> DB 비밀번호 셋은 **hex** 다. Base64 의 `/` `+` `=` `@` 가
> `postgresql://사용자:비번@호스트` 를 깨뜨린다.

> 납품(POSCO SWP)에서는 `AUTH_PROVIDER=swp` 로 바꾸고 `SWP_*` **열 개**를 더 넣는다.
> 양식은 같은 폴더의 `central-authority.env.example` 이고, 그 값들은 만드는 것이 아니라
> **SWP 등록값을 받아 적는 것**이다.
>
> ✔ **이름은 msa-ez 와 같다.** 앱이 읽는 이름을 코드에서 확인했다
> (`api/features/auth/config.py` 의 `SwpSettings.from_env`) — msa-ez 의
> `.env` 에 있는 `SWP_*` 값을 **이름 그대로** 옮겨 적으면 된다.
>
> ```text
> 그대로 옮긴다   SWP_SSO_LOGIN_URL · SWP_SSO_VALID_CHECK_URL · SWP_SSO_REDIRECT_URL
>                SWP_IDX_ID · SWP_IDX_EMPNO · SWP_IDX_DISPLAYNAME
>                SWP_IDX_MAIL · SWP_IDX_DEPT · SWP_EMAIL_FALLBACK_DOMAIN
> 우리만 있다     AUTH_CALLBACK_ALLOWLIST   ← **`SWP_` 가 아니다**
>                SWP_SSO_TIMEOUT_S         (선택 · 기본 15초)
> ```
>
> ⚠ **`SWP_IDX_*` 다섯은 비밀이 아니라 "몇 번째 칸인가" 다.** `isValidSSO.jsp`
> 가 돌려주는 CSV 의 **열 위치**(0부터)이고, 그중 `SWP_IDX_EMPNO` 가 **사람을
> 가리키는 사번**이 된다. 비워 두면 기본값(0·1·8·9·4)을 쓰는데, 실제 칸 순서가
> 다르면 **엉뚱한 칸을 사번으로 읽고도 오류가 나지 않는다.** 첫 연동 때
> `SWP_SSO_LOG_RAW=1` 로 한 번 원문을 찍어 **칸 순서를 눈으로 확인**한다.
>
> ⚠ **`AUTH_CALLBACK_ALLOWLIST` 를 비우면 loopback 만 허용된다** — 현장
> 콜백이 거부된다. 양식에 `SWP_SSO_CALLBACK_ALLOWLIST` 라고 잘못 적혀 있던
> 것을 2026-10-26 에 바로잡았다(그 이름은 **아무도 읽지 않았다**).

---

```text
[4번이 남기는 것]
만든다   C:\robo-central\.env                    9줄   compose 가 읽는다
                            ROBO_GRAPH_PASSWORD 가 여기 있다
         C:\robo-central\central-authority.env   7줄   authority 가 읽는다
                            AUTH_JWT_SECRET · AUTH_ROLE_SECRET · DSN 둘
         둘 다 chmod 600 / icacls 로 **나만 읽게** 잠근다
화면에    릴리스 <releaseId> · 설정 파일 둘 작성 완료

⚠ 이 둘을 **다시 만들지 않는다.** 비밀이 새 난수가 되어 이미 초기화된 DB 와
  어긋난다. 이미 다시 만들었으면 §9 의 `ALTER ROLE` 로 맞춘다
```

# 5. DB 를 띄우고 스키마·관리자·정책을 넣는다 — **바꿀 값 없음**

### (내 PC)

```powershell
docker compose up -d --wait graph-db graph-bolt
docker compose ps --format '{{.Service}}  {{.Status}}  {{.Ports}}'

$dsn = "postgresql://robo:$GRAPH_PW@graph-db:5432/robo"
"CREATE ROLE robo_authority LOGIN PASSWORD '$AUTH_RT_PW'; CREATE ROLE robo_operator LOGIN PASSWORD '$OPER_PW';" |
  docker compose exec -T graph-db psql -U robo -d robo -v ON_ERROR_STOP=1

foreach ($cmd in @(
  @('migrate'),
  @('grant','--employee-no',$ADMIN_EMPNO,'--reason','initial administrator'),
  @('policy','--approval-required','false','--reason','internal test')
)) {
  "--- $($cmd[0]) ---"
  docker compose run --rm --no-deps -e OG_PG_DSN="$dsn" authority python -m scripts.accounts_admin @cmd
}

"SELECT uid, role, status FROM public.app_users;" | docker compose exec -T graph-db psql -U robo -d robo
"SELECT initialized, approval_required, revision FROM public.app_auth_policy WHERE id=1;" | docker compose exec -T graph-db psql -U robo -d robo
"SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension;" | docker compose exec -T graph-db psql -U robo -d robo -At
```

### (서버)

```bash
docker compose up -d --wait graph-db graph-bolt
docker compose ps --format '{{.Service}}  {{.Status}}  {{.Ports}}'

DSN="postgresql://robo:$GRAPH_PW@graph-db:5432/robo"
echo "CREATE ROLE robo_authority LOGIN PASSWORD '$AUTH_RT_PW'; CREATE ROLE robo_operator LOGIN PASSWORD '$OPER_PW';" |
  docker compose exec -T graph-db psql -U robo -d robo -v ON_ERROR_STOP=1

docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin migrate
docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin grant --employee-no "$ADMIN_EMPNO" --reason "initial administrator"
docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin policy --approval-required true --reason "delivery approval policy"

echo 'SELECT uid, role, status FROM public.app_users;' | docker compose exec -T graph-db psql -U robo -d robo
echo 'SELECT initialized, approval_required, revision FROM public.app_auth_policy WHERE id=1;' | docker compose exec -T graph-db psql -U robo -d robo
echo "SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension;" | docker compose exec -T graph-db psql -U robo -d robo -At
```

**이렇게 나와야 한다**

```text
ps          graph-db · graph-bolt 두 줄 모두 (healthy)
            포트가 <SERVER_IP>:5432 · <SERVER_IP>:7687
CREATE ROLE 두 번
migrate     {"migrated": true}
grant       {"uid": "DEV-ADMIN", ..., "role": "admin", "status": "approved"}
policy      {"approval_required": ..., "revision": 2}
표 조회       DEV-ADMIN | admin | approved      ·      initialized = t
ontological, plpgsql, vector        ← 확장 셋. 비어 있으면 DB 가 속이 빈 것이다
```

> **`ps` 를 꼭 본다.** `pg_isready` 만 보면 초기화가 거부돼도 healthy 로 뜬다. 이
> compose 는 `og_catalog.graph` 표까지 확인하므로, 거부되면 `unhealthy` 로 남고
> `--wait` 가 거기서 선다.

> **`grant` 가 `initialized` 를 켠다.** `policy` 를 먼저 부르면 "먼저 최초 관리자를
> 지정해야 한다" 로 거절된다. 순서를 바꾸지 않는다.

> **(내 PC) 에서 `$args` 를 쓰지 않는다.** PowerShell 예약 변수여서 그 이름으로는 인자가
> 넘어가지 않는다. 위처럼 `$cmd` 를 쓴다.

> **`OG_PG_DSN` 은 일회성이다.** 상시 `authority` 서비스에는 넣지 않는다 — 그 서비스는
> `central-authority.env` 의 제한 역할로만 붙는다.

> `configure-access` 는 **지금 쓰지 않는다.** PC 가 아직 `robo`(특권 역할)로 붙어서
> "DB 역할은 미리 만든 제한된 역할이어야 합니다" 로 거절된다(done10 §192 의 미해결 항목).

---

```text
[5번이 남기는 것]
만든다   Docker 네트워크   robo-central_default
         Docker 볼륨      robo-central_graph_data   ← **팀의 설계 전부가 여기**
         컨테이너 둘       robo-central-graph-db-1 · robo-central-graph-bolt-1
         DB 역할 둘        robo_authority · robo_operator
         DB 표 셋          app_users · app_auth_policy · app_account_audit
         관리자 한 명      app_users 에 role=admin · status=approved
화면에    ps 두 줄 (healthy) · migrate/grant/policy 의 JSON 셋 · SELECT 두 표
```

# 6. 접속값을 넘긴다

### (내 PC) — 내 PC 가 곧 쓰는 PC 이므로 바로 넣는다

```powershell
[Environment]::SetEnvironmentVariable('ROBO_GRAPH_MODE',     'central',    'User')
[Environment]::SetEnvironmentVariable('ROBO_GRAPH_HOST',     $SERVER_IP,   'User')
[Environment]::SetEnvironmentVariable('ROBO_GRAPH_PASSWORD', $GRAPH_PW,    'User')
[Environment]::SetEnvironmentVariable('AUTH_ROLE_SECRET',    $ROLE_SECRET, 'User')
[Environment]::SetEnvironmentVariable('AUTH_JWT_SECRET',     $JWT_SECRET,  'User')
'넣었습니다'
```

**포트 변수는 넣지 않는다** — 기본 5432·7687 로 열었다.

#### 다른 PC 에도 줄 파일을 만든다 (내 PC · PowerShell)

PC 가 한 대뿐이면 건너뛴다. 두 대 이상이면 이 파일을 만들어 전달한다.

받는 사람은 `사용자-설치-가이드.md` §3 에서 `robo-env.ps1` 위쪽의 네 자리
(`$GRAPH_HOST`·`$GRAPH_PASSWORD`·`$ROLE_SECRET`·`$JWT_SECRET`)에 이 값을
**옮겨 적는다**. 파일을 그대로 실행해도 되지만, 그러면 값이 두 군데(이 파일과
`robo-env.ps1`)에 나뉘어 **다음에 무엇을 고쳐야 하는지** 헷갈린다.

```powershell
function Get-EnvVal($file, $key) { ((Get-Content $file | Where-Object { $_ -like "$key=*" }) -replace "^$key=", '') }
$SERVER_IP   = Get-EnvVal .\.env 'ROBO_GRAPH_BIND'
$GRAPH_PW    = Get-EnvVal .\.env 'ROBO_GRAPH_PASSWORD'
$ROLE_SECRET = Get-EnvVal .\central-authority.env 'AUTH_ROLE_SECRET'
$JWT_SECRET  = Get-EnvVal .\central-authority.env 'AUTH_JWT_SECRET'
@(
  "# Robo Architect 접속값 - 비밀을 담고 있다. 넣은 뒤 이 파일을 지운다."
  "[Environment]::SetEnvironmentVariable('ROBO_GRAPH_MODE',     'central', 'User')"
  "[Environment]::SetEnvironmentVariable('ROBO_GRAPH_HOST',     '$SERVER_IP', 'User')"
  "[Environment]::SetEnvironmentVariable('ROBO_GRAPH_PASSWORD', '$GRAPH_PW', 'User')"
  "[Environment]::SetEnvironmentVariable('AUTH_ROLE_SECRET',    '$ROLE_SECRET', 'User')"
  "[Environment]::SetEnvironmentVariable('AUTH_JWT_SECRET',     '$JWT_SECRET', 'User')"
  "'넣기 완료 - 로그아웃·재로그인 뒤 앱을 켜세요'"
) | Set-Content -Encoding utf8 .\pc-central-setup.ps1
icacls .\pc-central-setup.ps1 /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
"내보냈습니다: $(Resolve-Path .\pc-central-setup.ps1)  ($((Get-Content .\pc-central-setup.ps1).Count)줄)"
```

| 바꿀 값 | 없다 — 값을 `.env` 와 `central-authority.env` 에서 읽으므로 **창을 닫았어도 된다** |
|---|---|

**이렇게 나와야 한다**: **7줄**. 값이 들어갔는지 길이만 본다.

```powershell
Get-Content .\pc-central-setup.ps1 | Select-String "SetEnvironmentVariable" | ForEach-Object {
  if ($_ -match "Variable\('([A-Z_]+)',\s*'([^']*)'") { "{0,-22} 길이 {1}" -f $Matches[1], $Matches[2].Length }
}
```

```text
ROBO_GRAPH_MODE        길이 7      (= central)
ROBO_GRAPH_HOST        길이 11~15  (= IP 주소)
ROBO_GRAPH_PASSWORD    길이 64
AUTH_ROLE_SECRET       길이 64
AUTH_JWT_SECRET        길이 64
```

> **이 `set_line()` 블록은 bash 다.** (서버) 쪽 6번에 있는 그것을 PowerShell 에
> 붙여넣으면 `'(' 뒤에 식이 와야 합니다` 로 멈춘다. 내 PC 에서는 **이 블록**을 쓴다.

### (서버) — 파일 하나로 내보내 사용자들에게 준다

```bash
umask 077
set_line() { printf "[Environment]::SetEnvironmentVariable('%s', '%s', 'User')\n" "$1" "$2"; }
{
  echo "# Robo Architect 접속값 — 비밀을 담고 있다. 넣은 뒤 이 파일을 지운다."
  set_line ROBO_GRAPH_MODE     central
  set_line ROBO_GRAPH_HOST     "$SERVER_IP"
  set_line ROBO_GRAPH_PASSWORD "$GRAPH_PW"
  set_line AUTH_ROLE_SECRET    "$ROLE_SECRET"
  set_line AUTH_JWT_SECRET     "$JWT_SECRET"
  echo "'넣기 완료 — 로그아웃·재로그인 뒤 앱을 켜세요'"
} > pc-central-setup.ps1
chmod 600 pc-central-setup.ps1
wc -l pc-central-setup.ps1
```

**이렇게 나와야 한다**: **7줄**. 이 파일을 각 PC 에 전달하면 사용자는
`사용자-설치-가이드.md` **§3** 에서 `robo-env.ps1` 위쪽에 값 넷을 옮겨 적는다.

> **전달 경로는 조직이 정한다.** 비밀 셋이 평문으로 들어 있다. 메일·메신저로 보내지
> 않는다. 전달이 끝나면 양쪽에서 지운다.
> (`../2026-10-14/enterprise-todo11` §7-1 의 `A · 자격 전달` — 아직 미정)

---

```text
[6번이 남기는 것]
만든다   Windows **사용자 환경변수 다섯**
           ROBO_GRAPH_MODE · ROBO_GRAPH_HOST · ROBO_GRAPH_PASSWORD
           AUTH_ROLE_SECRET · AUTH_JWT_SECRET
         (다른 PC 에 줄 때만) C:\robo-central\pc-central-setup.ps1   7줄
화면에    넣었습니다 / 내보냈습니다: <경로> (7줄)
```

# 7. 다른 PC 를 붙일 때만 — 방화벽

PC 가 한 대뿐이면 건너뛴다.

### (내 PC)

```powershell
# 관리자 PowerShell
New-NetFirewallRule -DisplayName "Robo central PG"   -Direction Inbound -Protocol TCP -LocalPort 5432 -RemoteAddress 192.168.219.0/24 -Action Allow
New-NetFirewallRule -DisplayName "Robo central Bolt" -Direction Inbound -Protocol TCP -LocalPort 7687 -RemoteAddress 192.168.219.0/24 -Action Allow
```

### (서버)

```bash
sudo ufw allow from 10.10.0.0/24 to any port 5432 proto tcp
sudo ufw allow from 10.10.0.0/24 to any port 7687 proto tcp
sudo ufw status numbered
```

| 바꿀 값 | 무엇 |
|---|---|
| `192.168.219.0/24` · `10.10.0.0/24` | **PC 들이 있는 대역**. 전 대역(`0.0.0.0/0`)으로 열지 않는다 |

붙일 PC 에서 확인한다:

```powershell
foreach ($p in 5432,7687) { "{0} : {1}" -f $p, (Test-NetConnection -ComputerName 192.168.219.185 -Port $p -InformationLevel Quiet) }
```

두 줄 모두 `True` 여야 한다. `False` 면 방화벽 → `ROBO_GRAPH_BIND` 순서로 본다.

---

```text
[7번이 남기는 것]
만든다   방화벽 인바운드 규칙 둘 (5432 · 7687, PC 대역만)
화면에    두 포트가 True
```

# 8. 관리자 일은 끝 — 이제 사용자와 같다

```text
다음        `사용자-설치-가이드.md` 를 §0-A 부터 따라간다
            Ⓑ 내 PC 로 했으면 §3 의 **접속값 넷을 비워 둔다**(6번에서 이미 넣었다)
               — 빈 칸은 `robo-env.ps1` 이 건드리지 않는다
            Ⓐ 서버로 했으면 §3 의 그 넷에 아래에서 내보낸 값을 옮겨 적는다
```

---

# 9. 운영 — 나중에 보는 것

## 관리자 추가·해제

```bash
docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin grant  --employee-no <사번> --reason "<사유>"
docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin revoke --employee-no <사번> --reason "<사유>"
```

**마지막 승인된 관리자는 해제되지 않는다.** 교체할 때는 새 관리자를 먼저 `grant` 한 뒤
기존 관리자를 `revoke` 한다. 일상적인 승인·역할 변경은 앱의 **설정 → 사용자 관리**에서
한다.

## 표 셋이 무엇을 들고 있나

```text
public.app_users          사번 · 역할(admin/member) · 상태(approved/pending)
public.app_auth_policy    초기화 여부 · 승인제 사용 여부 · revision
public.app_account_audit  변경 전후 · 처리자 · 사유 · 시각
```

## 초기화를 빼먹으면 — **모든 로그인이 503**

```text
증상       로그인을 누르면 503 · AUTH_NOT_INITIALIZED
원인       app_auth_policy 의 initialized 가 false 이거나 표가 아예 없다
어디서      router.py 가 accounts.upsert_from_sso 를 부르고 store.py 가 거절한다.
           **로컬·중앙 구분이 없고** 개발용 로그인도 같이 막힌다
앱이 안 만든다  store.py 의 ensure_schema() 는 "서버 운영 명령 전용" 이고 앱 안에
           호출하는 곳이 없다. 부르는 것은 authority 이미지의 accounts_admin 이다
           (설치 EXE 에는 없다)
```

## 새 릴리스로 올릴 때 — ⚠ **`migrate` 를 다시 돌린다**

새 판이 표에 열이나 인덱스를 더하면 그것을 올리는 것은 **운영 명령뿐**이다.
앱이 아니다 — 중앙 구성에서 `/api/projects` 를 서비스하는 authority 는 표가
있는지만 보고 DDL 을 돌리지 않는다(아래 "초기화를 빼먹으면" 과 같은 이유).

```powershell
# 서버의 작업 폴더(C:\robo-central 또는 /opt/robo-central)에서.
# $dsn 은 5번에서 만든 그 값이다 — 창을 새로 열었으면 5번의 $dsn 줄을 먼저 다시 돌린다.
docker compose run --rm --no-deps -e OG_PG_DSN="$dsn" authority `
  python -m scripts.accounts_admin migrate
```

`{"migrated": true}` 가 나오면 끝이다. **여러 번 돌려도 안전하다** — 전부
`IF NOT EXISTS` 다. 데이터는 건드리지 않는다.

> **2026-10-22 판에서 더해진 것**: `app_projects` 의 `service_id` 생성열과
> 부분 유일 인덱스(서비스 ID 를 사람이 정하는 기능).
> 안 돌리면 프로젝트를 만들 때 **서비스 ID 칸이 거절된다** —
> *"유일성 검사가 아직 없습니다"* 라고 뜨고 `migrate` 를 돌리라고 말한다.
> 조용히 겹친 ID 를 받는 것보다 거절하는 쪽을 골랐다. 돌린 뒤에는 **앱을
> 다시 띄우지 않아도** 된다. 기존 프로젝트는 그대로다(값이 없는 상태).

---

## DB 이미지를 새 릴리스로 올릴 때 — ⚠ **정렬 규칙을 확인한다**

> ⚠⚠ **2026-10-27 판(그래프 엔진이 바뀐 판)은 예외다 — 볼륨을 새로 만들어야
> 한다.** 이 판은 데이터베이스 안의 표 구성이 늘었는데(카탈로그 17개 → 25개)
> 확장 판 번호가 그대로라, **초기화가 돌지 않고 새 코드가 없는 표를 찾는다.**
> 올리는 길을 따로 만들지 않았다.
>
> ```powershell
> docker compose --env-file .env -f compose.yml down          # -v 없이
> docker volume rm robo-central_graph_data                    # ⚠ 이름을 먼저 확인한다
> # .env 의 ROBO_IMAGE_* 를 새 releaseId 로 바꾼 뒤
> docker compose --env-file .env -f compose.yml up -d graph-db graph-bolt
> docker compose logs graph-db | Select-String -Pattern 'ontological-init'
> ```
>
> **이번에는 `initdb`·`ontological-init` 이 보여야 맞다**(아래 본문과 반대다).
> ⚠ 그러면 **프로젝트·설계·분석 데이터가 전부 사라진다.** 올리기 전에
> 사용자들에게 알리고, 필요하면 먼저 백업한다.
>
> ⚠⚠ **그리고 계정도 사라진다 — "최초 초기화" 를 다시 해야 한다.**
> 계정·정책·프로젝트 표(`public.app_*`)와 **DB 역할**은 그 볼륨 안에 있었다.
> 앱은 그 표를 스스로 만들지 않는다(만드는 자리는 **운영 명령 전용**이다).
> 안 돌리면 앱이 이렇게 된다 — 2026-10-27 에 실제로 겪었다:
>
> ```text
> GET /api/auth/provider → 500
>   UndefinedTable: relation "public.app_auth_policy" does not exist
> 화면은 그 요청을 2초마다 다시 보낸다 ⇒ **기동 중에서 안 넘어간다**
> ```
>
> 중앙 서버 `README.md` 의 **"2. 최초 초기화"** 를 그대로 다시 한다. 요점만:
>
> ```powershell
> # 1) 제한 LOGIN 역할 둘을 먼저 만든다 (DB 운영자가 한다)
> # 2) 운영자(superuser) DSN 을 **일회성으로** 주입해 스키마를 만든다
> #    ⚠ 상시 authority 서비스에는 이 DSN 을 절대 넣지 않는다
> docker compose run --rm --no-deps -e OG_PG_DSN authority `
>   python -m scripts.accounts_admin migrate
> docker compose run --rm --no-deps -e OG_PG_DSN authority `
>   python -m scripts.accounts_admin configure-access `
>   --server-role <authority역할> --client-role <PC역할>
> docker compose run --rm --no-deps -e OG_PG_DSN authority `
>   python -m scripts.accounts_admin grant --employee-no <실제사번> `
>   --reason "최초 관리자 지정"
> ```
>
> ⚠ **`migrate` 만 하고 멈추면 아무도 못 들어온다** — 정책이
> `approval_required=true` · `initialized=false` 로 시작하므로, 처음 들어온
> 사람은 **승인 대기**가 된다. 관리자 지정까지가 한 묶음이다.
> ⚠ 상시 `authority` 서비스의 DSN(제한 역할)으로는 이 명령이 **거절된다** —
> "서버 운영자 DB 자격이 필요합니다". 역할이 아직 없으면 연결 자체가 안 된다.
>
> ⚠ 그리고 이 판은 데이터 표에 **행 수준 보안(RLS)** 을 켠다. 올린 뒤
> **각 역할로 로그인해 자기 프로젝트가 보이는지** 꼭 확인한다 — 안 보이는
> 쪽이 오류 없이 조용히 나타난다.
> ⓘ 2026-10-27 에 재 보니 읽기 정책은 네 표 모두 `USING (true)` 이고 앱 계정이
>   superuser 라 **읽기가 걸러지지는 않는다**. 그래도 화면에서 한 번 센다.
>
> 아래 본문은 **엔진이 그대로인 판**을 올릴 때의 이야기다.

새 릴리스를 받으면 `.env` 의 `ROBO_IMAGE_*` 를 새 태그로 바꾸고 올린다.
**볼륨은 건드리지 않는다** — 데이터는 그대로 간다.

```powershell
# .env 의 세 줄을 새 releaseId 로 바꾼 뒤
docker compose --env-file .env -f compose.yml up -d graph-db graph-bolt
docker compose logs graph-db | Select-String -Pattern 'initdb'   # ← 아무것도 안 나와야 한다
```

`initdb` 가 보이면 **빈 디스크를 본 것**이다. 볼륨이 안 붙었다는 뜻이므로 **즉시
멈추고** 태그를 되돌린다.

### ⚠ 베이스 배포판이 바뀌면 **정렬 규칙이 어긋난다**

2026-10-22 에 `graph-db` 의 베이스가 Debian trixie → Ubuntu 24.04 로 바뀌었다
(취약점 보정). 배포판이 바뀌면 **glibc 가 바뀌고, glibc 가 바뀌면 문자 정렬
규칙이 바뀐다.** 올리자마자 이 경고가 났다:

```text
WARNING: database "robo" has a collation version mismatch
DETAIL:  The database was created using collation version 2.41,
         but the operating system provides version 2.39.
```

**데이터는 멀쩡해 보이고 집계도 다 맞는다.** 그런데 텍스트 인덱스가 **옛 규칙으로
서 있어서**, 인덱스를 타는 조회가 **오류 없이 행을 빠뜨릴 수** 있다.
조용히 틀리는 쪽이라 더 나쁘다.

```powershell
# 1) 경고가 있는지 본다
"SELECT datname, datcollversion FROM pg_database WHERE datname IN ('robo','postgres','template1');" |
  docker compose exec -T graph-db psql -U robo -d robo

# 2) 어긋나 있으면 인덱스를 새 규칙으로 다시 만든다 (241MB 기준 1분 남짓)
docker compose exec -T graph-db psql -U robo -d robo -v ON_ERROR_STOP=1 -c "REINDEX DATABASE robo"

# 3) 그다음에 버전 표시를 갱신한다 — **순서를 바꾸지 않는다**
docker compose exec -T graph-db psql -U robo -d postgres -v ON_ERROR_STOP=1 `
  -c "ALTER DATABASE robo REFRESH COLLATION VERSION"
docker compose exec -T graph-db psql -U robo -d postgres `
  -c "ALTER DATABASE postgres REFRESH COLLATION VERSION; ALTER DATABASE template1 REFRESH COLLATION VERSION"
```

> **`REFRESH` 를 먼저 하면 안 된다.** 그러면 경고만 사라지고 **옛 규칙으로 선
> 인덱스는 그대로 남는다.** 다시 만든 뒤에 표시를 갱신한다.

> `postgres` 역할은 없다 — 이 DB 의 superuser 는 `robo` 다.
> `psql -U postgres` 는 `role "postgres" does not exist` 로 막힌다.

끝나면 1)을 다시 돌려 **세 DB 가 같은 번호**인지 보고, 집계가 전과 같은지 확인한다.

---

## 백업 — **두 조각을 함께**

```text
DB 볼륨         robo-central_graph_data — 팀의 설계 전부가 여기 있다
설정 파일 둘      .env · central-authority.env — 비밀이 들어 있다
둘 중 하나만 있으면  복원이 안 된다. AUTH_ROLE_SECRET 을 잃으면 **사용자들이 자기
                프로젝트를 열 수 없다**(그 값에서 DB 비밀번호를 유도한다)
```

`down` 할 때 **`-v` 를 붙이지 않는다.** 볼륨이 지워지면 되돌릴 수 없다.

## 아직 확인되지 않은 것

```text
서버에 권한 API    authority 를 상시 띄워 실제 로그인부터 적재까지 돌린 기록이 없다
                 (done9 §180. 이미지·CLI·compose·fail-closed 만 확인)
실제 SWP          사내망에서만 된다. 지금은 시험 로그인 말고 들어갈 길이 없다
두 PC             락 충돌 · SSE · Bolt 세션 한계 · 분석 409 는 기계가 둘일 때만 보인다
PC 자격 제한       PC 가 아직 특권 역할 robo 로 붙는다 (done10 §192)
```

## 조직이 정해야 하는 것 둘

```text
자격 전달 경로     AUTH_ROLE_SECRET · AUTH_JWT_SECRET · ROBO_GRAPH_PASSWORD 셋을
                20여 대에 **같게** 넣는 길(USB·배포 도구·공유 폴더).
                AUTH_ROLE_SECRET 은 **한 번 정하면 못 바꾼다**
방화벽 범위        DB 를 사내망 어느 대역까지 열 것인가
```
