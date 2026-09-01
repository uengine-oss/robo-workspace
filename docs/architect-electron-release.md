# Robo Architect Electron 릴리스

## 전달 결과

일반 사용자에게 전달하는 결과는 Windows 설치본입니다.

```text
Robo-Architect-Setup-<release-id>.exe
```

대상 PC에는 실행 중인 Docker Desktop만 필요합니다. Git, Node.js, Java, Python,
uv, Neo4j Desktop 또는 소스 checkout은 필요하지 않습니다. 설치판 실행 시 Electron이
내장 manifest, 서비스별 환경 snapshot과 Docker image archive를 검증하고 app-owned
Compose stack과 Windows host의 Architect API를 자동으로 시작합니다.

일반 종료 때는 Architect API만 종료하고 Docker 서비스는 다음 실행을 위해 warm
상태로 둡니다. Neo4j와 MindsDB 데이터는 named volume에 보존되며 앱 재시작이나
일반적인 앱 제거로 삭제하지 않습니다.

## 반복 빌드

빌드 PC에는 Git, Node.js, uv, Docker Desktop이 필요합니다. 모든 변경을 각 저장소에
commit/push한 clean Workspace에서 한 줄을 실행합니다.

```cmd
robo.cmd release architect-electron
```

이 명령은 다음 단계를 순서대로 수행합니다.

1. 필요한 저장소가 없으면 clone하고, 있으면 main을 `pull --ff-only`로 동기화합니다.
2. Architect가 고정한 open-pencil 및 robo-analyzer submodule을 초기화합니다.
3. 필요한 Node dependency를 준비합니다.
4. Neo4j와 MindsDB image를 받고 Analyzer, Catalog, Data Fabric, Parser, Gateway
   image를 source commit label과 release tag로 빌드합니다.
5. 모든 image를 offline Docker archive로 저장합니다.
6. relocatable Windows CPython과 Architect FastAPI 소스를 묶습니다.
7. Analyzer remote와 Architect frontend, Electron TypeScript를 빌드합니다.
8. NSIS installer, runtime manifest와 SHA-256 파일을 생성합니다.

기본 출력은 다음과 같습니다.

```text
_releases/<release-id>/
  Robo-Architect-Setup-<release-id>.exe
  runtime-manifest.json
  SHA256SUMS
```

릴리스 명령은 dirty 저장소, 다른 branch와 submodule pointer 불일치를 거부합니다.
manifest는 모든 source commit, Docker image ID, offline archive SHA-256과 서비스
환경 snapshot SHA-256을 기록합니다. 실행 시 archive, local image 또는 snapshot
identity가 다르면 ready 상태로 진행하지 않습니다.

## 개발 빌드와의 차이

```cmd
robo.cmd up architect-electron -Build
robo.cmd build architect-electron unpacked
robo.cmd build architect-electron unpacked -SkipFrontend
```

위 명령은 개발 PC에서 빠르게 변경분을 확인하는 경로입니다. 기존 로컬 Python/Java
서비스와 개발 Neo4j를 사용하며 다른 PC에 전달할 완전한 번들이 아닙니다.
Docker images와 Windows Python까지 넣은 전달본은 `release`로만 만듭니다.

## 환경

`robo-workspace/.env`가 유일한 release-time 환경 입력입니다. fresh Workspace에서는
`.env.example`을 복사하고 비밀 값만 채웁니다.

```dotenv
ROBO_LLM_CONFIG=qwen38_sglang_local
ROBO_LLM_API_KEY=<internal-key>
LLM_PROVIDER=openai
LLM_MODEL=frentis-ai-model
OPENAI_BASE_URL=http://ai-server.dream-flow.com:30000/v1
OPENAI_API_KEY=<internal-key>
```

릴리스 명령은 이 입력을 Analyzer, Catalog, Data Fabric, Parser, Gateway, Architect
최소 권한 snapshot으로 나눕니다. 개발 Neo4j credential, source path, bind port,
서비스 내부 URL은 복사하지 않고 Electron과 Compose가 실행 topology에 맞춰 정합니다.
세부 계약은 [Workspace 환경 설정](environment.md)과
`release-environment.json`에 있습니다.

즉시 실행을 위해 넣는 내부 GPU credential은 Git이나 로그에 기록하지 않지만
installer 수신자는 기술적으로 추출할 수 있습니다. 설치본을 내부 배포물로 취급하고
의도한 범위를 벗어나면 credential을 회전해야 합니다.

## 실행 구조

```text
Robo Architect.exe
├─ Electron + Vue frontend
├─ bundled CPython + Architect FastAPI (Windows host)
└─ Docker Compose
   ├─ Neo4j
   ├─ Analyzer
   ├─ Catalog
   ├─ Data Fabric
   ├─ MindsDB
   ├─ ANTLR Parser
   └─ API Gateway
```

Architect API는 프로젝트 파일 경로, 설치된 CLI, IDE 통합과 ConPTY 같은 host 기능을
사용하므로 Windows에서 실행합니다. 데이터 서비스는 시작·업그레이드·진단을 한
stack으로 관리하기 위해 Docker로 실행합니다.

MindsDB는 offline archive에 고정 버전으로 포함되고 app-owned Docker network 안에서
실행되며 connector 상태는 별도 named volume에 보존됩니다. 사용자가 Windows에서
실행 중인 DB를 `localhost`로 등록하면 Data Fabric은 이를
`host.docker.internal`로 변환합니다.

## 프로젝트 폴더와 DDL 분류

설치판은 Windows 절대경로를 Linux container에 직접 넘기지 않습니다. 사용자가 폴더
하나를 선택하면 Electron main이 일반 파일을 읽고 상대경로를 보존해 app-owned
Gateway로 multipart 업로드합니다. `.git`, `node_modules`, `dist`, `target` 같은
생성 폴더는 제외합니다.

Parser가 단일 분류 권한을 가집니다.

- SQL이 아닌 파일은 source입니다.
- procedure, function, package, trigger, type 선언 SQL은 source입니다.
- table, view, index, sequence DDL SQL은 DDL입니다.

따라서 설치 UI에서 DDL 폴더를 별도로 고를 필요가 없습니다.

## 실제 검증 기준

2026-07-28 `shop_mall` 설치 환경 검증은 저장소별 `.env`가 아니라 생성된 packaged
snapshot을 사용했습니다.

- runtime 서비스 전체 health 통과
- 한 폴더의 13개 파일 업로드: C/H source 12개, schema DDL 1개 자동 분류
- 12개 exact AST, 12,344 lines, recovered/partial/unresolved/failed 0
- `qwen38_sglang_local` → 사내 SGLang `frentis-ai-model` 실제 호출 완료
- `BAAI/bge-m3` embedding 완료
- Neo4j 4,274 nodes, 11,586 relationships 생성
- PostgreSQL sample DB 22 tables와 row, FK inference function을 실제 생성하고
  app-owned MindsDB/Data Fabric 경로의 연결·등록·metadata·sample query 검증
- 종료 후 검증용 container와 volume 제거

## macOS 경계

Electron UI 소스는 운영체제 공통이지만 현재 릴리스 파이프라인은 Windows 전용입니다.
`robo.cmd`와 release 구현이 PowerShell/Windows executable, Windows CPython,
`win-unpacked`와 NSIS target을 명시합니다.

macOS 지원에는 별도 Darwin Python runtime, arm64/amd64 Docker image archive,
`.dmg` target, code signing/notarization과 실제 Mac 검증이 필요합니다. 현재는
구조를 참고할 수 있지만 “같은 명령으로 Mac 설치본 생성 가능”으로 안내하지 않습니다.
