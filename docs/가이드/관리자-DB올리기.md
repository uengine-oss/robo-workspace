# 관리자 — **DB 를 올린다** (리눅스 서버)

```text
관리자가 더 하는 일   DB 컨테이너 둘을 올리고 접속값을 만든다. **그것뿐이다.**
그다음              사용자와 **똑같이** `사용자-설치-가이드.md` 를 따라 각 PC 에 앱을 깐다
한 번만             DB 는 한 곳에 한 번 올린다. 사용자가 늘어도 다시 하지 않는다
전제                리눅스 서버 · Docker Engine + compose v2 · openssl · 릴리스 폴더
걸리는 시간          이미지 올리기 5~10분 + 나머지 2분
```

**채우는 것은 파일 하나다.** 릴리스의 `central-server/robo-central.sh` 를 열어
`[고치는 곳]` 의 **값 둘**(서버 IP · 최초 관리자 사번)을 적고 돌린다. 단계마다
셸을 붙여넣지 않는다 — PC 쪽의 `robo-env.ps1` 과 같은 방식이다.

```bash
cd <릴리스폴더>/central-server
vi robo-central.sh          # [고치는 곳] 의 SERVER_IP · ADMIN_EMPNO
sudo bash robo-central.sh
```

> **윈도우 PC 에 올리려는 경우**는 **부록 A** 로 간다. 서버를 아직 못 쓸 때
> 쓰는 시험용 길이고, 그쪽만 PowerShell 이다. 납품 구성은 이 본문이다.

---

## 이 가이드가 서버에 남기는 것 — 한 장

| 어디에 | 무엇이 | 얼마나 |
|---|---|---|
| `/opt/robo-central/` | 작업 폴더 — compose · 매니페스트 · README · **채운 `robo-central.sh`** | 5개 파일 |
| 같은 폴더 | `.env` · `central-authority.env` — **비밀이 여기 있다** (chmod 600) | 11줄 · 7줄 |
| 같은 폴더 | `pc-central-setup.ps1` — 각 PC 에 줄 접속값 | 8줄 |
| Docker | 이미지 **10개** · 네트워크 1 · 볼륨 `robo-central_graph_data` 1 | 1.95GB |
| Docker | 컨테이너 둘 — `graph-db`(5432) · `graph-bolt`(7687) | |
| DB 안 | 역할 둘 · 표 셋 · **최초 관리자 한 명** | |
| 방화벽 | 인바운드 둘 (PC 대역만) | |

**지우면 되돌릴 수 없는 것**은 볼륨 `robo-central_graph_data` 와 설정 파일 둘이다.
`down` 할 때 **`-v` 를 붙이지 않는다** — 스크립트의 `down` 도 붙이지 않는다.

---

## 내가 정하는 값은 **둘**뿐이다 — 나중에 고칠 것은 **하나**

```text
내가 적는다      SERVER_IP     DB 를 공개할 사내망 IP
                ADMIN_EMPNO   최초 관리자의 사번
기계가 만든다     비밀 다섯 (ROBO_GRAPH_PASSWORD · robo_authority · robo_operator ·
                AUTH_ROLE_SECRET · AUTH_JWT_SECRET) — 사람이 고르지 않는다
받아 적는다      SWP 값 열 (납품) — ⚠ 조직이 바꾸지 않았다면 **비워 두는 것이 맞다**
```

### ⚠ 나중에 고치게 되는 것은 **`SERVER_IP` 하나다**

DHCP 면 주소가 바뀐다. 그때 고쳐야 하는 자리는 **셋**인데, 스크립트가 **둘을**
해 준다. 남은 하나는 각 PC 다. 하나라도 빠뜨리면 **오류 없이** 안 된다.

```text
rebind 가 한다   ① 작업 폴더 `.env` 의 ROBO_GRAPH_BIND · ROBO_AUTHORITY_BIND
                ② 컨테이너 다시 만들기 (--force-recreate)
사람이 한다      ③ 각 PC 의 ROBO_GRAPH_HOST
                  (사용자 가이드 §3 의 `robo-env.ps1` → $GRAPH_HOST)
```

```bash
# SERVER_IP 를 새 주소로 고친 뒤
sudo bash /opt/robo-central/robo-central.sh rebind
```

> **증상이 조용하다.** 주소가 없어지면 컨테이너는 `Up (healthy)` 인 채로 떠 있고,
> `docker ps` 의 **Ports 칸만 빈다.** 사용자 쪽에는 `fabric is unhealthy` 로
> 엉뚱하게 나타난다. 그러니 **Ports 칸을 먼저 본다** (`check` 가 그 칸을 본다).

> ⚠ **순서가 있다.** 주소를 고치는 일이 **사용자 PC 의 앱보다 먼저**다.
> 환경변수는 컨테이너가 **뜰 때** 박히므로, 앱이 먼저 뜨면 그 컨테이너는 옛
> 주소를 쥔 채 `unhealthy` 가 된다. 고친 뒤에는 **앱을 껐다가 바탕화면
> 아이콘으로 다시 띄운다** — 중앙만 다시 올려서는 안 풀린다.

> 애초에 **고정 IP(정적 할당 또는 DHCP 예약)로 받는 것**이 이 일을 없앤다.

---

## 순서대로 — **이것만 한다**

각 줄의 `#` 주석이 그 단계의 설명이다. 왜 그런지는 아래 절에 있다.
**(서버)** 는 전부 bash 다. 윈도우 PC 에 올리려면 **부록 A** 로 간다.

```bash
# ① 릴리스를 서버로 옮긴다 (약 2GB) — 보내는 쪽(윈도우 PowerShell)에서:
#      cd <robo-workspace 폴더>
#      scp -r ".\_releases\<릴리스ID>" <계정>@<서버IP>:/tmp/robo-release
#    USB 를 못 쓰면 깃으로 받는다 → 납품물-전달.md

# ② 온전한지 본다 — **여덟 줄 모두 OK** 여야 한다
cd /tmp/robo-release
sha256sum -c SHA256SUMS

# ③ 값 둘을 채운다 — SERVER_IP · ADMIN_EMPNO (SWP 칸은 보통 비운다)
hostname -I                                 # 여기 나온 사내망 IP 를 적는다
vi central-server/robo-central.sh           # 맨 위 [고치는 곳] 만 본다

# ④ 돌린다 — 이 한 번이 적재·비밀·DB·스키마·관리자·정책을 순서대로 한다
#    끊기면 **다시 돌려도 된다**(이미 만든 비밀은 그대로 둔다)
sudo bash central-server/robo-central.sh

# ⑤ 사용자 PC 에 줄 접속값을 전달한다 — ⚠ 메일·메신저로 보내지 않는다
ls -l /opt/robo-central/pc-central-setup.ps1

# ⑥ PC 가 여럿일 때만 — 방화벽을 PC 대역에만 연다
sudo ufw allow from <PC대역>.0/24 to any port 5432 proto tcp
sudo ufw allow from <PC대역>.0/24 to any port 7687 proto tcp
sudo ufw status numbered
```

끝났으면 각 PC 에 `사용자-설치-가이드.md` 대로 앱을 깐다.

```bash
# 나중에 상태를 볼 때 — 아무것도 바꾸지 않는다
sudo bash /opt/robo-central/robo-central.sh check
# 서버 IP 가 바뀌었을 때 (⚠ 각 PC 의 ROBO_GRAPH_HOST 도 함께 고쳐야 한다)
sudo bash /opt/robo-central/robo-central.sh rebind
```

---

# 1. 릴리스를 서버로 옮긴다

폴더째로 옮긴다. `central-server/` 만 옮기면 **`robo-images.tar` 가 없어서**
스크립트가 멈춘다.

```bash
# 보내는 쪽(내 PC · PowerShell). $REL 은 굽기가 만든 폴더다 —
# 목록으로 그때 값을 확인한다:
#   robo-workspace 폴더에서:  Get-ChildItem .\_releases -Directory | Sort-Object LastWriteTime
cd <robo-workspace 폴더>
scp -r ".\_releases\<릴리스ID>" <계정>@<서버IP>:/tmp/robo-release
```

> **USB 로 들고 갈 수 없을 때**는 깃으로 받는다 — 작은 것들은 가지에, 큰 파일
> 둘은 릴리스 자산으로 올린다. 만드는 길과 받는 길은 **`납품물-전달.md`** 에 있다.

받는 쪽에서 온전한지 먼저 본다.

```bash
cd /tmp/robo-release
sha256sum -c SHA256SUMS
```

**여덟 줄 모두 `OK`** 여야 한다. 하나라도 `FAILED` 면 다시 옮긴다 — 이 다음
단계들이 전부 그 파일에 기댄다.

```text
[1번이 남기는 것]
만든다   /tmp/robo-release — 릴리스 폴더 한 벌 (약 2GB)
화면에    SHA256SUMS 의 모든 줄이 OK
```

---

# 2. 파일 하나를 채운다 — `robo-central.sh`

```bash
cd /tmp/robo-release/central-server
vi robo-central.sh
```

맨 위의 **`[고치는 곳]`** 만 본다. 그 아래 `[아래는 손대지 않는다]` 는 읽지
않아도 된다.

| 칸 | 무엇 | 어떻게 정하나 |
|---|---|---|
| **1 `SERVER_IP`** | DB 를 공개할 **사내망 IP** | `hostname -I` 의 주소. ⚠ **IP 로 적는다**(호스트 이름이 아니라) — 2026-10-15 결정. 같은 값이 각 PC 의 컨테이너 여덟에도 들어가고, Bolt 는 평문 인증이다. `127.*` · `0.0.0.0` 은 스크립트가 **거절한다** |
| **2 `ADMIN_EMPNO`** | 최초 관리자의 **사번(uid)** | 납품이면 조직이 정한 실제 사번. 시험이면 `DEV-ADMIN` — 그러면 앱에서 `admin`/`admin` 으로 들어간다 |
| 3 `AUTH_PROVIDER` | 로그인 방식 | 납품 `swp` · 사내 시험 `none` |
| 3 `APPROVAL_REQUIRED` | 신규 사용자를 관리자가 승인해야 쓰게 하나 | 납품 `true` |
| 4 `SWP_*` 열 | SWP 등록값 | ⚠ **비워 두는 것이 맞다** — 아래를 읽는다 |
| 5 `PG_PORT`·`BOLT_PORT` | 포트를 옮길 때만 | 보통 비운다. 아래 "포트가 부딪힐 때" |
| 6 `WORK_DIR` | 작업 폴더 | 보통 `/opt/robo-central` 그대로 |

### ⚠ SWP 값 열은 **만드는 것이 아니라 받아 적는 것**이고, 보통 **비운다**

`msa-ez/platform` **v1.0.30** 의 `docker-compose.yml` 과 대조해 두었다. 같은
조직의 플랫폼이고, **SWP 값 아홉이 우리 코드 기본값과 전부 같았다.** 그러니
조직이 바꾸지 않았다면 비워 두는 것이 맞다. 막히면 그 저장소를 먼저 본다.

이름은 msa-ez 와 같다 — 앱이 읽는 이름을 코드에서 확인했다
(`api/features/auth/config.py` 의 `SwpSettings.from_env`).

```text
같다 — 비운다   SWP_SSO_LOGIN_URL · SWP_SSO_VALID_CHECK_URL · SWP_SSO_REDIRECT_URL
               SWP_IDX_ID · SWP_IDX_EMPNO · SWP_IDX_DISPLAYNAME
               SWP_IDX_MAIL · SWP_IDX_DEPT · SWP_EMAIL_FALLBACK_DOMAIN
우리만 있다     AUTH_CALLBACK_ALLOWLIST   ← **`SWP_` 가 아니다**
               (msa-ez 에는 `CALLBACK` 이라는 이름이 **없다** — 웹앱이라 자기 origin)
선택           SWP_SSO_TIMEOUT_S   기본 15초
```

> ⚠ **`SWP_IDX_*` 다섯은 비밀이 아니라 "몇 번째 칸인가" 다.** `isValidSSO.jsp`
> 가 돌려주는 CSV 의 **열 위치**(0부터)이고, 그중 `SWP_IDX_EMPNO` 가 **사람을
> 가리키는 사번**이 된다. 비우면 기본값(0·1·8·9·4)을 쓰는데, 실제 칸 순서가
> 다르면 **엉뚱한 칸을 사번으로 읽고도 오류가 나지 않는다.** 첫 연동 때
> `SWP_SSO_LOG_RAW=1` 로 한 번 원문을 찍어 **칸 순서를 눈으로 확인**한다.

> ⚠ **`AUTH_CALLBACK_ALLOWLIST` 는 양쪽으로 함정이다.**
> 비우면 콜백이 **loopback 만** 허용된다(`localhost` · `127.0.0.1` · `::1`).
> 채우면 **그 loopback 자동허용이 사라지고** 적은 origin 만 허용된다.
> 그러므로 채울 때는 현장 origin 을 **빠뜨리지 않고** 적는다.
> (양식에 `SWP_SSO_CALLBACK_ALLOWLIST` 라고 잘못 적혀 있던 것을 2026-10-26 에
> 바로잡았다 — 그 이름은 **아무도 읽지 않았다.**)

전체 양식은 같은 폴더의 `central-authority.env.example` 에 있다. 스크립트가
`[고치는 곳]` 4번의 값으로 그 파일을 만들어 주므로, 양식을 손으로 베끼지 않는다.

### 포트가 부딪힐 때 — **msa-ez 를 내리지 않는다**

그 서버에 msa-ez platform 이 이미 돌고 있다. 5432 가 부딪히는지는 **어느
구성이냐**에 달렸다 — 실제로 재서 확인한 것은 이렇다(v1.0.30).

```text
통합 구성      docker-compose.yml          postgres 를 **127.0.0.1:5432** 에 묶는다
               → 우리는 <SERVER_IP>:5432 에 묶으므로 **부딪히지 않는다.** 내릴 필요 없다
분리 DB 서버   docker-compose.split.db.yml postgres 를 **5432:5432**(모든 주소)
               → **부딪힌다**
```

부딪히면 **우리 포트를 옮긴다.** `[고치는 곳]` 5번에 `PG_PORT=55432` 처럼 적는다.
`compose.yml` 이 그 자리를 열어 두었다 —
`${ROBO_GRAPH_PG_PORT:-5432}` · `${ROBO_GRAPH_BOLT_PORT:-7687}`.

⚠ 그러면 **각 PC 에도 같은 값을 넣어야 한다** — `robo-env.ps1` 의 `[고치는 곳]`
에 `$GRAPH_PG_PORT` · `$GRAPH_BOLT_PORT` 자리가 있다. 스크립트가 만드는
`pc-central-setup.ps1` 에도 그 줄이 함께 들어간다.

msa-ez 를 꼭 내려야 한다면 **`-v` 를 붙이지 않는다**(볼륨까지 지워 그쪽
데이터가 사라진다).

```bash
docker compose -f docker-compose.split.db.yml down
docker volume ls | grep msaez
```

```text
[2번이 남기는 것]
만든다   채운 robo-central.sh 한 파일
확인     SERVER_IP 와 ADMIN_EMPNO 가 비어 있지 않다 (비면 3번이 멈춘다)
```

---

# 3. 돌린다 — **한 번**

```bash
cd /tmp/robo-release/central-server
sudo bash robo-central.sh
```

이 한 번이 아래를 **순서대로** 한다. 중간에 끊기면 **다시 돌려도 된다** —
이미 만든 비밀 다섯은 그대로 두고 이어간다.

```text
점검          docker · compose v2 · openssl · SERVER_IP 모양 · 포트 비었나
              ⚠ **셸에 남은 ROBO_* 환경변수가 있으면 여기서 멈춘다**
작업 폴더      /opt/robo-central 을 세우고 자기 자신까지 복사한다
부품 묶음      robo-images.tar 를 올린다 (이미 있으면 건너뛴다)
설정 파일      .env · central-authority.env 를 쓴다 (chmod 600)
DB 기동        graph-db · graph-bolt 를 띄우고 DB 역할 둘을 넣는다
스키마·관리자   migrate → grant → policy  (⚠ 이 순서를 바꾸지 않는다)
확인          확장 · 관리자 · initialized
접속값         pc-central-setup.ps1 을 쓰고 **길이만** 보여 준다
```

**이렇게 나와야 한다**

```text
== 점검 ==
  v 셸에 남은 환경변수 없음
  v SERVER_IP = 10.10.0.5
== DB 기동 ==
    graph-db    Up (healthy)   10.10.0.5:5432->5432/tcp
    graph-bolt  Up (healthy)   10.10.0.5:7687->7687/tcp
  v DB 역할 둘 (robo_authority · robo_operator)
== 스키마 · 관리자 · 정책 ==
  migrate
    {"migrated": true}
  grant M123456
    {"uid": "M123456", ..., "role": "admin", "status": "approved"}
  policy approval-required=true
    {"approval_required": true, "revision": 2}
== 확인 ==
    확장: ontological, plpgsql, vector      ← 비어 있으면 DB 가 속이 빈 것이다
    관리자: M123456 | admin | approved
  v 초기화 됨 (initialized = t)
== 사용자 PC 에 줄 파일 ==
    /opt/robo-central/pc-central-setup.ps1   (8줄)
      ROBO_GRAPH_MODE        길이 7
      ROBO_GRAPH_HOST        길이 9
      ROBO_GRAPH_PASSWORD    길이 64
      AUTH_ROLE_SECRET       길이 64
      AUTH_JWT_SECRET        길이 64
```

### 왜 이렇게 보는지

> **`Up (healthy)` 와 Ports 칸을 함께 본다.** `pg_isready` 만 보면 초기화가
> 거부돼도 healthy 로 뜬다. 설계와 분석 graph 이름을 같게 주면 훅이 올바르게
> 거부하는데(데이터는 지켜진다) 컨테이너는 그대로 뜨고 `ps` 는 healthy 라고
> 말한다 — 2026-10-01 예행에서 실제로 그랬다. 그래서 이 compose 는
> `og_catalog.graph` 표까지 확인한다. 거부되면 `unhealthy` 로 남고 `--wait` 가
> 거기서 선다.

> **`grant` 가 `initialized` 를 켠다.** `policy` 를 먼저 부르면 "먼저 최초
> 관리자를 지정해야 한다" 로 거절된다. 스크립트가 순서를 지킨다.
> ⚠ **`migrate` 만 하고 멈추면 아무도 못 들어온다** — 정책이
> `approval_required=true` · `initialized=false` 로 시작하므로, 처음 들어온
> 사람은 **승인 대기**가 된다. 관리자 지정까지가 한 묶음이다.

> **비밀 다섯을 다시 만들지 않는다.** 다시 만들면 이미 초기화된 DB 와 어긋나고,
> 증상은 **"모든 로그인 실패"** 로만 나타난다. 스크립트는 `.env` 에 값이 있으면
> **그대로 쓴다.** 이미 어긋났으면 §7-2 로 맞춘다.

> **`OG_PG_DSN` 은 일회성이다.** 상시 `authority` 서비스에는 넣지 않는다 — 그
> 서비스는 `central-authority.env` 의 제한 역할로만 붙는다. 스크립트가 운영
> 명령에만 `-e` 로 준다. ⚠ 상시 서비스의 DSN(제한 역할)으로는 이 명령이
> **거절된다** — *"서버 운영자 DB 자격이 필요합니다"*. 역할이 아직 없으면
> 연결 자체가 안 된다.

> `configure-access` 는 **지금 쓰지 않는다.** PC 가 아직 `robo`(특권 역할)로
> 붙어서 "DB 역할은 미리 만든 제한된 역할이어야 합니다" 로 거절된다
> (done10 §192 의 미해결 항목).

```text
[3번이 남기는 것]
만든다   /opt/robo-central/{.env · central-authority.env · pc-central-setup.ps1}
         Docker 네트워크 robo-central_default
         Docker 볼륨    robo-central_graph_data   ← **팀의 설계 전부가 여기**
         컨테이너 둘     robo-central-graph-db-1 · robo-central-graph-bolt-1
         DB 역할 둘      robo_authority · robo_operator
         DB 표 셋        app_users · app_auth_policy · app_account_audit
         관리자 한 명    app_users 에 role=admin · status=approved
```

---

# 4. 접속값을 사용자들에게 준다

스크립트가 `/opt/robo-central/pc-central-setup.ps1` 을 만들어 두었다. 이 파일을
각 PC 에 전달하면, 받는 사람은 `사용자-설치-가이드.md` **§3** 에서
`robo-env.ps1` 위쪽의 네 자리(`$GRAPH_HOST` · `$GRAPH_PASSWORD` ·
`$ROLE_SECRET` · `$JWT_SECRET`)에 **옮겨 적는다.**

파일을 그대로 실행해도 되지만, 그러면 값이 두 군데(이 파일과 `robo-env.ps1`)에
나뉘어 **다음에 무엇을 고쳐야 하는지** 헷갈린다.

> **전달 경로는 조직이 정한다.** 비밀 셋이 평문으로 들어 있다. 메일·메신저로
> 보내지 않는다. 전달이 끝나면 **양쪽에서 지운다.**
> (`../2026-10-14/enterprise-todo11` §7-1 의 `A · 자격 전달` — 아직 미정)

다시 보고 싶으면 **값을 찍지 않고** 길이만 본다.

```bash
sudo bash /opt/robo-central/robo-central.sh check
```

```text
[4번이 남기는 것]
만든다   없음 — 3번이 만든 파일을 전달할 뿐이다
화면에    이름마다 길이 (값은 나오지 않는다)
```

---

# 5. 다른 PC 를 붙일 때만 — 방화벽

PC 가 한 대뿐이면 건너뛴다.

```bash
sudo ufw allow from 10.10.0.0/24 to any port 5432 proto tcp
sudo ufw allow from 10.10.0.0/24 to any port 7687 proto tcp
sudo ufw status numbered
```

| 바꿀 값 | 무엇 |
|---|---|
| `10.10.0.0/24` | **PC 들이 있는 대역**. 전 대역(`0.0.0.0/0`)으로 열지 않는다 |

붙일 PC 에서 확인한다 (PowerShell):

```powershell
foreach ($p in 5432,7687) { "{0} : {1}" -f $p, (Test-NetConnection -ComputerName 10.10.0.5 -Port $p -InformationLevel Quiet) }
```

두 줄 모두 `True` 여야 한다. `False` 면 **방화벽 → `ROBO_GRAPH_BIND`** 순서로 본다.

```text
[5번이 남기는 것]
만든다   방화벽 인바운드 규칙 둘 (5432 · 7687, PC 대역만)
화면에    두 포트가 True
```

---

# 6. 관리자 일은 끝 — 이제 사용자와 같다

```text
다음   `사용자-설치-가이드.md` 를 §0-A 부터 따라 각 PC 에 앱을 깐다
       §3 의 접속값 넷에 4번에서 받은 값을 옮겨 적는다
```

---

# 7. 운영 — 나중에 보는 것

## 7-1. 주소가 바뀌었을 때

위 **"나중에 고치게 되는 것은 `SERVER_IP` 하나다"** 를 본다. `rebind` 가 둘을
하고, **각 PC 의 `ROBO_GRAPH_HOST`** 는 사람이 한다.

## 7-2. 관리자 추가·해제

```bash
cd /opt/robo-central
DSN="postgresql://robo:$(sed -n 's/^ROBO_GRAPH_PASSWORD=//p' .env)@graph-db:5432/robo"
docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin grant  --employee-no <사번> --reason "<사유>"
docker compose run --rm --no-deps -e OG_PG_DSN="$DSN" authority \
  python -m scripts.accounts_admin revoke --employee-no <사번> --reason "<사유>"
```

**마지막 승인된 관리자는 해제되지 않는다.** 교체할 때는 새 관리자를 먼저
`grant` 한 뒤 기존 관리자를 `revoke` 한다. 일상적인 승인·역할 변경은 앱의
**설정 → 사용자 관리**에서 한다.

비밀이 어긋났을 때(설정 파일을 다시 만들어 버렸을 때)는 DB 쪽을 맞춘다.
`robo-central.sh` 를 다시 돌리면 역할이 있으면 `ALTER ROLE` 로 **맞춰 준다** —
`.env` · `central-authority.env` 에 적힌 값이 기준이다.

```bash
sudo bash /opt/robo-central/robo-central.sh
```

## 7-3. 표 셋이 무엇을 들고 있나

```text
public.app_users          사번 · 역할(admin/member) · 상태(approved/pending)
public.app_auth_policy    초기화 여부 · 승인제 사용 여부 · revision
public.app_account_audit  변경 전후 · 처리자 · 사유 · 시각
```

## 7-4. 초기화를 빼먹으면 — **모든 로그인이 503**

```text
증상       로그인을 누르면 503 · AUTH_NOT_INITIALIZED
원인       app_auth_policy 의 initialized 가 false 이거나 표가 아예 없다
어디서      router.py 가 accounts.upsert_from_sso 를 부르고 store.py 가 거절한다.
           **로컬·중앙 구분이 없고** 개발용 로그인도 같이 막힌다
앱이 안 만든다  store.py 의 ensure_schema() 는 "서버 운영 명령 전용" 이고 앱 안에
           호출하는 곳이 없다. 부르는 것은 authority 이미지의 accounts_admin 이다
           (설치 EXE 에는 없다)
```

`robo-central.sh` 의 `check` 가 이것을 본다 — `initialized` 가 `t` 가 아니면 멈춘다.

## 7-5. 새 릴리스로 올릴 때 — ⚠ **`migrate` 를 다시 돌린다**

새 판이 표에 열이나 인덱스를 더하면 그것을 올리는 것은 **운영 명령뿐**이다.
앱이 아니다 — 중앙 구성에서 `/api/projects` 를 서비스하는 authority 는 표가
있는지만 보고 DDL 을 돌리지 않는다(7-4 와 같은 이유).

```bash
sudo bash /opt/robo-central/robo-central.sh migrate
```

`{"migrated": true}` 가 나오면 끝이다. **여러 번 돌려도 안전하다** — 전부
`IF NOT EXISTS` 다. 데이터는 건드리지 않는다.

> **2026-10-22 판에서 더해진 것**: `app_projects` 의 `service_id` 생성열과
> 부분 유일 인덱스(서비스 ID 를 사람이 정하는 기능).
> 안 돌리면 프로젝트를 만들 때 **서비스 ID 칸이 거절된다** —
> *"유일성 검사가 아직 없습니다"* 라고 뜨고 `migrate` 를 돌리라고 말한다.
> 조용히 겹친 ID 를 받는 것보다 거절하는 쪽을 골랐다. 돌린 뒤에는 **앱을
> 다시 띄우지 않아도** 된다. 기존 프로젝트는 그대로다(값이 없는 상태).

## 7-6. DB 이미지를 새 릴리스로 올릴 때 — ⚠ 손으로 한다

> ⚠⚠ **2026-10-27 판(그래프 엔진이 바뀐 판)은 예외다 — 볼륨을 새로 만들어야
> 한다.** 이 판은 데이터베이스 안의 표 구성이 늘었는데(카탈로그 17개 → 25개)
> 확장 판 번호가 그대로라, **초기화가 돌지 않고 새 코드가 없는 표를 찾는다.**
> 올리는 길을 따로 만들지 않았다 — 그래서 `robo-central.sh` 도 이 일을
> **하지 않는다.**
>
> ```bash
> cd /opt/robo-central
> docker compose --env-file .env -f compose.yml down     # -v 없이
> docker volume rm robo-central_graph_data               # ⚠ 이름을 먼저 확인한다
> # .env 의 ROBO_IMAGE_* 세 줄을 새 releaseId 로 바꾼 뒤
> docker compose --env-file .env -f compose.yml up -d graph-db graph-bolt
> docker compose logs graph-db | grep ontological-init
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
> 되살리는 길은 **`robo-central.sh` 를 다시 돌리는 것**이다 — 역할·스키마·
> 관리자·정책을 그 순서로 다시 넣고, 비밀 다섯은 `.env` 에 있는 그대로 쓴다.
>
> ⚠ 그리고 이 판은 데이터 표에 **행 수준 보안(RLS)** 을 켠다. 올린 뒤
> **각 역할로 로그인해 자기 프로젝트가 보이는지** 꼭 확인한다 — 안 보이는
> 쪽이 오류 없이 조용히 나타난다.
> ⓘ 2026-10-27 에 재 보니 읽기 정책은 네 표 모두 `USING (true)` 이고 앱 계정이
>   superuser 라 **읽기가 걸러지지는 않는다**. 그래도 화면에서 한 번 센다.
>
> 아래는 **엔진이 그대로인 판**을 올릴 때의 이야기다.

새 릴리스를 받으면 `.env` 의 `ROBO_IMAGE_*` 를 새 태그로 바꾸고 올린다.
**볼륨은 건드리지 않는다** — 데이터는 그대로 간다.

```bash
cd /opt/robo-central
# .env 의 세 줄을 새 releaseId 로 바꾼 뒤
docker compose --env-file .env -f compose.yml up -d graph-db graph-bolt
docker compose logs graph-db | grep initdb   # ← 아무것도 안 나와야 한다
```

`initdb` 가 보이면 **빈 디스크를 본 것**이다. 볼륨이 안 붙었다는 뜻이므로 **즉시
멈추고** 태그를 되돌린다. 그다음 `robo-central.sh migrate` 를 돌린다.

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

```bash
cd /opt/robo-central
# 1) 경고가 있는지 본다
echo "SELECT datname, datcollversion FROM pg_database WHERE datname IN ('robo','postgres','template1');" |
  docker compose exec -T graph-db psql -U robo -d robo

# 2) 어긋나 있으면 인덱스를 새 규칙으로 다시 만든다 (241MB 기준 1분 남짓)
docker compose exec -T graph-db psql -U robo -d robo -v ON_ERROR_STOP=1 -c "REINDEX DATABASE robo"

# 3) 그다음에 버전 표시를 갱신한다 — **순서를 바꾸지 않는다**
docker compose exec -T graph-db psql -U robo -d postgres -v ON_ERROR_STOP=1 \
  -c "ALTER DATABASE robo REFRESH COLLATION VERSION"
docker compose exec -T graph-db psql -U robo -d postgres \
  -c "ALTER DATABASE postgres REFRESH COLLATION VERSION; ALTER DATABASE template1 REFRESH COLLATION VERSION"
```

> **`REFRESH` 를 먼저 하면 안 된다.** 그러면 경고만 사라지고 **옛 규칙으로 선
> 인덱스는 그대로 남는다.** 다시 만든 뒤에 표시를 갱신한다.

> `postgres` 역할은 없다 — 이 DB 의 superuser 는 `robo` 다.
> `psql -U postgres` 는 `role "postgres" does not exist` 로 막힌다.

끝나면 1)을 다시 돌려 **세 DB 가 같은 번호**인지 보고, 집계가 전과 같은지 확인한다.

## 7-7. 백업 — **두 조각을 함께**

```text
DB 볼륨         robo-central_graph_data — 팀의 설계 전부가 여기 있다
설정 파일 둘      .env · central-authority.env — 비밀이 들어 있다
둘 중 하나만 있으면  복원이 안 된다. AUTH_ROLE_SECRET 을 잃으면 **사용자들이 자기
                프로젝트를 열 수 없다**(그 값에서 DB 비밀번호를 유도한다)
```

`down` 할 때 **`-v` 를 붙이지 않는다.** 볼륨이 지워지면 되돌릴 수 없다.
스크립트의 `down` 은 붙이지 않는다.

```bash
sudo bash /opt/robo-central/robo-central.sh down   # 컨테이너만 내린다
```

## 7-8. 안 될 때 — 보는 순서

```text
1  bash robo-central.sh check        Ports 칸 · 확장 · initialized 를 한 번에 본다
2  Ports 칸이 비었다                 주소가 바뀌었다 → rebind
3  unhealthy 로 남는다               docker compose logs graph-db
                                    설계·분석 graph 이름이 같으면 훅이 거부한다
4  모든 로그인 503                   7-4 (initialized)
5  PC 에서 fabric is unhealthy       PC 의 ROBO_GRAPH_HOST 가 옛 주소다
6  "남은 환경변수" 로 멈춘다          ~/.bashrc · /etc/environment 를 지우고 재로그인
```

---

# 8. 아직 확인되지 않은 것

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

---

# 부록 A — 서버 없이 **내 PC** 에 올릴 때 (시험용)

서버를 아직 못 쓸 때의 길이다. 납품 구성이 아니다. `robo-central.sh` 는 bash 라
윈도우에서 돌지 않으므로, **이 부록만 PowerShell** 로 같은 일을 한다.

> 본문의 bash 블록을 PowerShell 에 붙여넣지 않는다 —
> `sha256sum 용어가 인식되지 않습니다` 같은 오류가 난다.

## A-1. 남은 환경변수를 지운다

> **왜 먼저 하나.** `docker compose` 는 **셸 환경변수를 `.env` 파일보다 먼저**
> 읽는다. 지난 설치의 `ROBO_GRAPH_PASSWORD` 가 남아 있으면 DB 가 **그 옛
> 비밀번호로 초기화되고** 뒷 단계가 "DB 연결·스키마·운영 권한을 확인하세요" 로
> 실패한다. 2026-10-14 에 실제로 그렇게 막혔다.
> (본문의 스크립트는 이것을 **거절**한다.)

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

## A-2. 이미지를 올리고 작업 폴더를 만든다

```powershell
# ⚠ 릴리스 ID 는 굽기가 정한다. 아래로 **그때 값**을 확인해 넣는다 —
#   robo-workspace 폴더에서:  Get-ChildItem .\_releases -Directory | Sort-Object LastWriteTime
$WS    = "<robo-workspace 폴더>"
$RELID = "<릴리스ID>"
$REL   = "$WS\_releases\$RELID"
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

## A-3. 값을 정한다 — **두 줄**

```powershell
$SERVER_IP   = '192.168.219.185'
$ADMIN_EMPNO = 'DEV-ADMIN'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } |
  Select-Object IPAddress, InterfaceAlias | Format-Table -AutoSize
```

⚠ **`vEthernet (WSL)` 주소는 쓰지 않는다** — 다른 PC 가 못 닿는다.
`localhost` · `127.0.0.1` · `0.0.0.0` 도 안 된다.

## A-4. 설정 파일 둘을 만든다 — **바꿀 값 없음**

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

> **이 창(셸)을 닫지 않는다.** `GRAPH_PW` · `ROLE_SECRET` · `JWT_SECRET` 은
> 여기에만 있고 A-5·A-6 에서 쓴다. 닫았으면 두 `.env` 파일에서 다시 읽는다.

> DB 비밀번호 셋은 **hex** 다. Base64 의 `/` `+` `=` `@` 가
> `postgresql://사용자:비번@호스트` 를 깨뜨린다.

> ⚠ 이 둘을 **다시 만들지 않는다.** 비밀이 새 난수가 되어 이미 초기화된 DB 와
> 어긋난다. 이미 다시 만들었으면 §7-2 로 맞춘다.

> 납품(POSCO SWP)에서는 `AUTH_PROVIDER=swp` 로 바꾸고 `SWP_*` 를 더 넣는다 —
> 어느 값을 넣고 어느 값을 비우는지는 본문 **2번**을 읽는다.

## A-5. DB 를 띄우고 스키마·관리자·정책을 넣는다

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

> **`$args` 를 쓰지 않는다.** PowerShell 예약 변수여서 그 이름으로는 인자가
> 넘어가지 않는다. 위처럼 `$cmd` 를 쓴다.

확인할 것은 본문 3번의 "이렇게 나와야 한다" 와 같다.

## A-6. 접속값을 넣는다

내 PC 가 곧 쓰는 PC 이므로 바로 넣는다.

```powershell
[Environment]::SetEnvironmentVariable('ROBO_GRAPH_MODE',     'central',    'User')
[Environment]::SetEnvironmentVariable('ROBO_GRAPH_HOST',     $SERVER_IP,   'User')
[Environment]::SetEnvironmentVariable('ROBO_GRAPH_PASSWORD', $GRAPH_PW,    'User')
[Environment]::SetEnvironmentVariable('AUTH_ROLE_SECRET',    $ROLE_SECRET, 'User')
[Environment]::SetEnvironmentVariable('AUTH_JWT_SECRET',     $JWT_SECRET,  'User')
'넣었습니다'
```

**포트 변수는 넣지 않는다** — 기본 5432·7687 로 열었다.
그다음 `사용자-설치-가이드.md` §3 에서 **접속값 넷을 비워 둔다**(여기서 이미
넣었고, 빈 칸은 `robo-env.ps1` 이 건드리지 않는다).

다른 PC 에도 줄 파일이 필요하면 값을 파일에서 **읽어** 만든다 — 창을 닫았어도 된다.

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

**이렇게 나와야 한다**: **7줄**. 값은 보지 않고 길이만 본다.

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

## A-7. 방화벽 (다른 PC 를 붙일 때만)

```powershell
# 관리자 PowerShell
New-NetFirewallRule -DisplayName "Robo central PG"   -Direction Inbound -Protocol TCP -LocalPort 5432 -RemoteAddress 192.168.219.0/24 -Action Allow
New-NetFirewallRule -DisplayName "Robo central Bolt" -Direction Inbound -Protocol TCP -LocalPort 7687 -RemoteAddress 192.168.219.0/24 -Action Allow
```

`192.168.219.0/24` 는 **PC 들이 있는 대역**이다. 전 대역(`0.0.0.0/0`)으로 열지
않는다. 붙일 PC 에서 두 포트가 `True` 인지 본문 5번처럼 확인한다.

## A-8. 운영

본문 **§7** 과 같다. 명령만 PowerShell 로 바꿔 읽는다 —
`sed -n 's/^KEY=//p' .env` 대신 위 `Get-EnvVal`, `grep` 대신 `Select-String`.
