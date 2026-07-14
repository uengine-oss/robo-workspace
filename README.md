# Robo Workspace

Robo Workspace는 여러 개로 나뉜 Robo Git 저장소를 **한 번에 준비하고 실행하고
종료하는 Windows용 관리 도구**입니다.

Robo는 하나의 프로그램처럼 보이지만 실제로는 Analyzer, parser, Gateway,
data-fabric, Architect UI처럼 역할이 다른 서비스가 각각 독립 저장소에 있습니다.
예전에는 저장소마다 서버를 직접 켜야 했고, 포트나 실행 순서를 하나라도
틀리면 전체가 동작하지 않았습니다. 이 도구가 그 배선을 대신 관리합니다.

## 1. 어떤 문제를 해결하나요?

Robo Workspace 하나로 다음 작업을 할 수 있습니다.

- 필요한 독립 저장소를 `project/` 아래에 자동 clone
- Python과 Node 의존성 설치
- 실행 전 도구·저장소·Neo4j·포트 상태 검사
- 필요한 서비스를 올바른 순서로 시작하고 실제 health 응답까지 대기
- 웹 UI 또는 Electron 앱 실행
- 자신이 시작한 프로세스만 안전하게 종료
- 여러 저장소를 수정 내용 손실 없이 동기화
- Electron 실행 파일과 설치 파일 빌드

코드를 모노레포로 합치거나 Architect 아래에 같은 저장소를 다시 중첩하지
않습니다. 각 저장소는 계속 독립 Git 저장소이고, [workspace.json](workspace.json)이
“어떤 프로필에 어떤 저장소와 서비스가 필요한지”를 기록한 배선도입니다.

## 가장 빠른 시작

### 새 PC에서 처음 실행하는 경우

먼저 다음 프로그램이 필요합니다.

| 필수 프로그램 | 기준 | 왜 필요한가요? |
|---|---|---|
| Windows 10/11 | 64-bit | 현재 원샷 실행기와 Electron 빌드 대상 |
| Git | PATH에서 `git` 실행 가능 | 독립 저장소 clone·동기화 |
| Python | 3.11 이상 | Analyzer, catalog, data-fabric |
| uv | PATH에서 `uv` 실행 가능 | Architect Python 환경 |
| Node.js + npm | 현재 LTS 권장 | 웹 UI와 Electron 빌드 |
| Java | 17 | parser와 Gateway 실행 |
| Neo4j | Bolt `7687` | Robo 그래프 저장소 |

원하는 빈 폴더에서 Workspace만 clone합니다. 나머지 저장소는 `setup`이 자동으로
형제 `project/` 폴더에 받습니다. Architect가 직접 빌드에 사용하는
`open-pencil`만 필요한 서브모듈로 초기화하며, Analyzer 계열은 중첩 복제하지
않고 형제 독립 저장소를 사용합니다.

```cmd
mkdir C:\robo
cd /d C:\robo
git clone https://github.com/uengine-oss/robo-workspace.git
cd robo-workspace
robo.cmd setup architect-electron
```

처음 `setup`이 끝나면 로컬 환경설정 파일이 생성됩니다.

```cmd
notepad .env
```

최소한 실행 중인 Neo4j의 값에 맞게 다음 항목을 채웁니다. 실제 비밀번호를
README, 채팅, 커밋에 올리면 안 됩니다.

```dotenv
ROBO_NEO4J_URI=bolt://127.0.0.1:7687
ROBO_NEO4J_USER=neo4j
ROBO_NEO4J_PASSWORD=여기에_로컬_비밀번호
ROBO_NEO4J_DATABASE=neo4j
```

Neo4j를 시작한 뒤 Electron을 실행합니다.

```cmd
robo.cmd doctor architect-electron
robo.cmd up architect-electron
```

`Robo Architect` 창이 나타나면 성공입니다. 사용을 마치면 반드시 공통 서비스까지
함께 종료합니다.

```cmd
robo.cmd down architect-electron
```

### 이미 설치가 끝난 PC에서 평소 실행하는 경우

```cmd
cd /d C:\robo\robo-workspace
robo.cmd up architect-electron
```

종료:

```cmd
robo.cmd down architect-electron
```

기존 Electron 산출물은 기본으로 재사용합니다. 소스를 수정해 강제로 새 산출물이
필요할 때만 `-Build`를 붙이십시오. 산출물이 없으면 자동으로 최초 빌드합니다.

## 2. 프로필은 무엇인가요?

프로필은 “무엇을 실행할지”를 고르는 이름입니다.

| 프로필 | 실행되는 것 | 결과 |
|---|---|---|
| `analyzer` | parser, Analyzer, catalog, data-fabric, Gateway, Analyzer UI | 브라우저 `http://127.0.0.1:3000` |
| `architect-web` | 공통 백엔드 5종, Analyzer remote, Architect API, Architect UI | 브라우저 `http://127.0.0.1:5173` |
| `architect-electron` | 공통 백엔드 5종, 빌드된 Architect 데스크톱 앱, 앱 내부 Architect API | `Robo Architect` Electron 창 |
| `all` | Analyzer UI와 Architect 웹 UI, 양쪽에 필요한 로컬 서비스 전체 | 브라우저 `http://127.0.0.1:3000`, `http://127.0.0.1:5173` |

Analyzer만 확인하려면 `analyzer`, Architect를 브라우저로 확인하려면
`architect-web`, 두 웹 UI를 한 번에 개발하려면 `all`, 실제 데스크톱 앱을
확인하려면 `architect-electron`을 씁니다.

두 웹 UI와 필요한 서비스를 한 번에 실행하고 종료하는 기본 명령은 다음 두 줄입니다.

```cmd
robo.cmd up all
robo.cmd down all
```

한 서버만 수정했을 때 전체를 재시작할 필요가 없습니다. 프로필은 현재 실행한
프로필과 맞추고 서비스 ID만 지정합니다.

```cmd
robo.cmd restart all -Service analyzer
robo.cmd down all -Service catalog
robo.cmd up all -Service catalog
```

`up`과 `restart`는 기존 프런트엔드/Electron 빌드 결과를 기본으로 재사용합니다.
결과물이 없을 때만 자동 빌드하며, 소스를 수정해 강제로 다시 빌드할 때만
`-Build`를 붙입니다.

```cmd
robo.cmd restart all
robo.cmd restart all -Build
```

- Analyzer UI: `http://127.0.0.1:3000`
- Architect UI: `http://127.0.0.1:5173`
- API Gateway: `http://127.0.0.1:9000` (화면 주소가 아니라 두 UI의 API 경유지)

## 3. 명령어는 각각 무슨 뜻인가요?

| 명령 | 의미 | 언제 사용하나요? |
|---|---|---|
| `help` | 간단한 사용법 표시 | 명령이 기억나지 않을 때 |
| `setup` | 저장소 clone + 의존성 설치 | PC마다 프로필별 최초 1회, 의존성이 바뀐 뒤 |
| `doctor` | 실행 조건과 포트 검사 | `up` 전에 문제가 없는지 확인할 때 |
| `up` | 기존 빌드를 재사용하고 모든 서비스를 시작 | 실제 실행할 때 |
| `restart` | 관리 중인 서비스를 종료하고 다시 시작 | Electron 창을 닫은 뒤 다시 띄울 때 |
| `status` | 관리 중인 프로세스 상태 표시 | 제대로 떠 있는지 확인할 때 |
| `logs` | 서비스별 최근 로그 표시 | 실행 실패 원인을 볼 때 |
| `down` | 이 도구가 시작한 프로세스 트리 종료 | 사용을 마쳤을 때, 재실행 전에 |
| `sync` | 안전한 저장소 업데이트 | 다른 사람의 최신 커밋을 받을 때 |
| `build` | Electron 패키지 생성 | exe 또는 installer가 필요할 때 |

아무 인자 없이 `robo.cmd`를 실행하면 이 요약이 터미널에 표시됩니다.

어떤 프로필을 실행했는지 기억나지 않거나 여러 상태가 함께 남아 있으면 한 줄로
Workspace가 관리하는 전체 프로필을 종료할 수 있습니다.

```cmd
robo.cmd down all
```

수동 실행 서버까지 포함해 모든 Robo 프로필 포트를 정리해야 할 때만 다음 명령을
사용합니다. Neo4j는 종료 대상에 포함되지 않습니다.

```cmd
robo.cmd down all -ForcePorts
```

## 4. 지금 이 PC에서 직접 해보기

현재 작업 경로가 `D:\work\robo`라면 아래 명령을 그대로 복사해서 실행할 수
있습니다. **한 프로필을 시험한 뒤 반드시 `down`하고 다음 프로필을 실행**하세요.
프로필들이 같은 포트를 공유하기 때문입니다.

### 4-1. 먼저 공통 확인

Neo4j Desktop에서 DB를 시작해 Bolt 포트 `7687`이 열려 있어야 합니다.

```cmd
cd /d D:\work\robo\robo-workspace
robo.cmd
```

이미 이 PC에는 의존성 설치가 완료되어 있습니다. 다른 PC나 새 clone에서는
시험할 프로필에 대해 먼저 다음을 실행합니다.

```cmd
robo.cmd setup architect-web
```

`setup complete`가 나오면 준비가 끝난 것입니다. 최초 setup은 다운로드 때문에
몇 분 걸릴 수 있습니다.

### 4-2. Architect 웹 직접 실행

```cmd
cd /d D:\work\robo\robo-workspace
robo.cmd doctor architect-web
robo.cmd up architect-web
```

예상 결과:

1. 각 서비스마다 `[ OK ] ... ready`가 표시됩니다.
2. 마지막에 `Open http://127.0.0.1:5173`이 표시됩니다.
3. 브라우저에서 `http://127.0.0.1:5173`을 열면 Robo Architect 화면이 나옵니다.

상태와 로그를 보고 종료합니다.

```cmd
robo.cmd status architect-web
robo.cmd logs architect-web
robo.cmd down architect-web
```

프런트 소스를 수정해 Analyzer remote를 다시 만들어야 할 때만 `-Build`를
붙입니다.

```cmd
robo.cmd up architect-web -Build
```

`up`은 반복 실행해도 안전합니다. 서비스가 모두 살아 있으면 이미 실행 중이라고
알리고 성공하며, Electron 창을 직접 닫아 일부만 종료된 상태라면 남은 공통
백엔드를 자동 정리하고 다시 시작합니다.

### 4-3. Architect Electron 직접 실행

```cmd
cd /d D:\work\robo\robo-workspace
robo.cmd doctor architect-electron
robo.cmd up architect-electron
```

예상 결과:

1. 공통 백엔드 5종이 준비됩니다.
2. 실제 `desktop\out\dist\win-unpacked\Robo-Architect.exe`가 실행됩니다.
3. `Robo Architect` 데스크톱 창이 표시됩니다.
4. Electron 내부에서 Architect API가 빈 포트를 골라 자동 시작됩니다.

사용을 마치면 창만 닫는 대신 아래 명령으로 공통 백엔드까지 함께 정리하십시오.

```cmd
robo.cmd status architect-electron
robo.cmd down architect-electron
```

Electron 창을 닫은 뒤 바로 다시 띄우려면 한 줄이면 됩니다.

```cmd
robo.cmd restart architect-electron
```

실수로 `up`을 다시 입력해도 stale 상태를 감지해 같은 방식으로 복구합니다.

다른 터미널에서 같은 서버를 수동 실행했거나 이전 상태 파일이 유실되어 프로필
포트가 남았다면, 명시적으로 해당 프로필 포트까지 정리한 뒤 재시작할 수 있습니다.

```cmd
robo.cmd restart architect-electron -ForcePorts
```

`-ForcePorts`는 선택한 프로필의 서비스 포트 점유 프로세스까지 종료합니다. Neo4j와
프로필 밖의 포트는 건드리지 않지만, 해당 포트에서 다른 작업을 수행 중이라면 함께
종료될 수 있으므로 일반적인 재시작에서는 붙이지 않습니다.

최신 소스로 프런트와 앱을 강제로 다시 빌드해 실행하려면 `-Build`를 붙입니다. 첫
빌드는 약 1~3분 걸릴 수 있습니다.

```cmd
robo.cmd up architect-electron -Build
```

Architect 저장소에서도 같은 명령을 더 짧게 실행할 수 있습니다.

```cmd
cd /d D:\work\robo\project\robo-architect
scripts\dev-desktop.cmd -SkipBuild
scripts\dev-desktop.cmd -Stop
```

### 4-4. Analyzer UI 직접 실행

```cmd
cd /d D:\work\robo\robo-workspace
robo.cmd doctor analyzer
robo.cmd up analyzer
```

브라우저에서 `http://127.0.0.1:3000`을 열어 확인한 뒤 종료합니다.

```cmd
robo.cmd down analyzer
```

## 5. Electron 실행 파일과 설치 파일 만들기

프런트부터 모두 새로 빌드한 unpacked 실행 파일:

```cmd
robo.cmd build architect-electron unpacked
```

결과:

```text
project\robo-architect\desktop\out\dist\win-unpacked\Robo-Architect.exe
```

Windows NSIS 설치 파일:

```cmd
robo.cmd build architect-electron installer
```

결과:

```text
project\robo-architect\desktop\out\dist\Robo-Architect-Setup-0.1.0.exe
```

프런트를 방금 빌드했고 패키징만 다시 하고 싶다면 `-SkipFrontend`을 붙일 수
있습니다.

```cmd
robo.cmd build architect-electron installer -SkipFrontend
```

주의: 현재 산출물은 **개발용 패키지**입니다. Python backend runtime까지
포함한 완전 독립 설치본은 아직 아니므로, 다른 PC에 설치 파일 하나만 전달하는
배포 방식은 별도의 runtime bundle 작업 후 지원해야 합니다.

## 6. 저장소 동기화는 안전한가요?

```cmd
robo.cmd sync architect-electron
```

`sync`은 각 독립 저장소를 확인하고 다음 조건일 때만 `pull --ff-only` 합니다.

- 수정 파일이 없음
- 해당 저장소의 기본 브랜치에 있음

수정 중인 dirty 저장소와 다른 브랜치는 `[WARN] ... skipped`로 건너뜁니다.
사용자 작업을 자동으로 stash, reset, checkout하지 않습니다.

Workspace 실행기 자체와 모든 서비스 저장소를 최신화하는 권장 순서는 다음과
같습니다.

```cmd
cd /d C:\robo\robo-workspace
git pull --ff-only
robo.cmd sync architect-electron
robo.cmd setup architect-electron
```

- `git pull --ff-only`: Workspace 실행기 자체 업데이트
- `sync`: 수정 중이 아닌 서비스 저장소만 안전하게 업데이트
- `setup`: 새로 추가되거나 변경된 의존성을 다시 맞춤

업데이트로 프런트 또는 Electron 소스가 바뀌었다면 첫 실행에 `-Build`를 붙여
최신 산출물을 만드는 것이 안전합니다.

## 7. 포트와 서비스 배선

| 서비스 | 로컬 포트 |
|---|---:|
| Analyzer | 5502 |
| catalog | 5503 |
| data-fabric | 8404 |
| parser | 8401 |
| Gateway | 9000 |
| Analyzer federation remote | 5001 |
| Architect web API | 8501 |
| Architect web UI | 5173 |
| Analyzer 전용 UI | 3000 |

이 PC에서는 Windows가 8001·8004·8081을 예약해 애플리케이션이 사용할 수
없습니다. 그래서 로컬 실행은 8501·8404·8401을 사용하고, UI와 Gateway에는
실제 주소를 환경변수로 전달합니다. 배포 기본값 자체를 강제로 바꾸지는 않습니다.

## 8. 문제가 생기면

### `doctor found blocking problems`

바로 위 `[FAIL]` 줄을 확인합니다.

- `Neo4j port 7687 is not listening`: Neo4j Desktop에서 DB 시작
- `repository missing`: `robo.cmd setup <profile>` 실행
- `port ... already in use`: 출력된 PID를 확인하고 다른 프로필을 `down`하거나,
  프로필 포트 전체를 정리해도 되는 경우에만 안내된 `-ForcePorts` 명령 실행
- `cannot be bound`: Windows 예약 포트 또는 권한 문제

### `state already exists`

현재 버전에서는 이 오류 대신 실행 상태를 자동 판별합니다. 최신 Workspace인지
`git pull --ff-only`로 확인한 뒤 다음 한 줄로 재시작할 수 있습니다.

```cmd
robo.cmd restart <profile>
```

### 서비스 readiness 실패

실패한 서비스와 로그 경로가 오류에 표시됩니다. 전체 최근 로그는 다음으로
확인합니다.

```cmd
robo.cmd logs <profile>
```

중간 서비스가 실패하면 그 전에 시작된 프로세스도 자동 롤백합니다. `down`은
`.robo/<profile>-state.json`에 기록된 프로세스 트리만 종료하며, 사용자가 따로
띄운 Electron이나 같은 포트의 무관한 프로그램을 전역 검색해 죽이지 않습니다.
상태와 무관하게 선택한 프로필의 포트 리스너까지 종료하려면 사용자가 명시적으로
`-ForcePorts`를 추가해야 합니다.

Catalog의 `/health`는 프로세스 상태만 뜻합니다. Workspace는 실제 기동 판정에
Neo4j-backed `/robo/check-data/`를 사용하고, 시작 전 `doctor`에서 Neo4j 인증도
확인합니다. 브라우저 모드에서 인증 오류가 나면 `robo-workspace\.env`의
`ROBO_NEO4J_*` 값을 확인해야 합니다.

프로세스 종료 로직을 수정한 뒤 격리 회귀 테스트를 실행하려면 다음 명령을 사용합니다.
테스트는 실제 서비스 포트가 아닌 임시 빈 포트만 사용합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\process-ownership.ps1
```

## 9. 경로와 환경설정

기본 구조:

```text
D:\work\robo\
├─ robo-workspace\        공통 실행기와 배선도
└─ project\               독립 Git 저장소들
   ├─ robo-architect\
   ├─ robo-data-analyzer\
   ├─ robo-data-frontend\
   ├─ robo-data-catalog\
   ├─ robo-data-fabric\
   ├─ antlr-code-parser\
   └─ api-gateway\
```

저장소 위치가 다르면:

```cmd
set ROBO_PROJECT_ROOT=D:\다른경로\robo-projects
robo.cmd setup architect-web
```

Architect의 호환 스크립트가 다른 Robo Workspace를 사용해야 하면:

```cmd
set ROBO_WORKSPACE_DIR=D:\다른경로\robo-workspace
scripts\dev-desktop.cmd
```

Neo4j와 비밀 값은 Git에 올리지 않는 `robo-workspace\.env` 또는 각 서비스의
로컬 `.env`에서 관리합니다. 비밀번호와 API 키를 README나 스크립트에 직접
적지 마십시오.
