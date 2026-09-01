# Distributable Electron Docker release

## Goal

`robo.cmd release architect-electron` 한 명령으로 Windows x64 배포본을 만든다.
산출물은 개발 저장소, Python, Java, Node, Neo4j Desktop 없이 실행되며 사용자는
Docker Desktop만 설치한다.

## Distribution boundary

- Electron과 Architect API는 호스트에서 실행한다.
- Architect API는 installer에 포함한 relocatable Python runtime과 소스에서 실행한다.
- Neo4j, Analyzer, Catalog, Data Fabric, ANTLR Parser, API Gateway는 Electron이 소유한
  Docker Compose project로 실행한다.
- Docker image archive를 installer에 포함해 첫 실행이 registry 가용성에 의존하지 않는다.
- Neo4j data는 named volume에 보존하고 앱 종료 시 container만 내린다.

## Scenarios

1. **Release build**
   - Given 모든 pinned repository와 submodule이 clean하고 source commit이 존재한다.
   - When `robo.cmd release architect-electron`을 실행한다.
   - Then 서비스 image, offline archive, bundled Architect runtime, frontend, Electron,
     NSIS installer, SHA-256 manifest가 한 release directory에 생성된다.
2. **Clean-machine first launch**
   - Given Docker Desktop은 실행 중이나 Robo image가 하나도 없다.
   - When 사용자가 installer를 설치하고 Robo Architect를 실행한다.
   - Then Electron이 offline archive를 한 번 load하고 Compose stack과 Architect API를
     순서대로 준비해 UI를 연다.
3. **Normal relaunch**
   - Given image가 이미 load됐고 Neo4j named volume이 존재한다.
   - When 앱을 다시 실행한다.
   - Then image import 없이 stack을 올리고 기존 graph data를 그대로 사용한다.
4. **Shutdown**
   - Given app이 stack과 local Architect API를 소유한다.
   - When app을 종료한다.
   - Then local API는 종료되고 Compose container는 warm 상태로 남아 다음 실행에서 재사용된다.
     명시적 `engine stop` 또는 제거 흐름만 container를 중지하며 Neo4j named volume은 남는다.
5. **Docker unavailable**
   - Given Docker CLI 또는 daemon이 없다.
   - When 앱을 시작한다.
   - Then 저장소나 host tool로 폴백하지 않고 Docker Desktop 필요 오류와 로그 위치를 표시한다.
6. **Partial failure**
   - Given image load, Compose health, local API 중 한 단계가 실패한다.
   - When startup budget이 끝난다.
   - Then 앱은 ready가 되지 않고 실패 단계와 복구 동작을 표면화하며 고아 프로세스를 남기지 않는다.
7. **Workspace-only release**
   - Given 새 Windows PC에 Workspace checkout과 Git, Node, uv, Docker Desktop만 있다.
   - When `robo.cmd release architect-electron`을 실행한다.
   - Then 명령이 누락된 source repository와 pinned submodule 및 Node dependencies를
     준비하고 동일 명령 안에서 installer를 생성한다.
8. **Packaged GPU environment**
   - Given Workspace `.env`에 서비스별 runtime 값이 있다.
   - When release를 만든다.
   - Then 값은 Analyzer/Catalog/Fabric/Architect용 최소 권한 env snapshot으로 분리되고,
     설치판 Analyzer는 `qwen38_sglang_local` GPU 설정으로 LLM client를 구성한다.
9. **Electron local-folder analysis**
   - Given Windows의 `shop_mall` 폴더에 C source와 schema SQL이 함께 있다.
   - When 설치판 Electron에서 그 폴더를 선택해 분석한다.
   - Then Electron이 파일의 상대경로를 보존해 app-owned Gateway로 반입하고 Parser가
     SQL 내용을 기준으로 DDL과 source를 canonical shared volume에 분리한다. Windows
     절대경로를 Linux container에 직접 전달하지 않는다.

## Requirements

- release는 dirty repository/submodule을 묵시적으로 패키징하지 않는다.
- image tag와 runtime manifest는 source commit으로 고정한다.
- Neo4j password는 image, installer, manifest, 로그에 포함하지 않고 첫 실행에 생성한다.
- 내부 즉시 실행 배포용 GPU/API credential은 Git과 로그에는 포함하지 않지만 release-time
  service env snapshot으로 installer에 포함된다. 따라서 installer는 내부 배포물이며
  credential 회수/회전 단위로 취급한다.
- Workspace `.env`는 서비스 설정의 단일 release input이다. 서비스 checkout의 ignored
  `.env` 존재 여부에 release 결과가 달라지지 않는다.
- Docker stack은 외부에 Gateway, Analyzer MCP와 Neo4j Bolt만 bind하고 내부 서비스는
  전용 network에 둔다.
- host Architect API는 Docker 내부 Neo4j URI와 Gateway host port를 환경으로 받는다.
- release 실패는 non-zero exit이며 부분 산출물을 성공으로 보고하지 않는다.
- build와 runtime 검증은 생성 artifact 자체를 대상으로 한다.
- committed `.env.example`은 실제 서비스 source가 소비하는 runtime 설정을
  활성 기본값 또는 주석 처리된 선택 override로 열거하고 회귀 테스트로 대조한다.
- `setup`의 clone과 `sync`의 fast-forward 동작은 임시 local Git remote를 사용하는
  격리 contract test로 검증하고 테스트 checkout을 남기지 않는다.

## Non-goals

- Docker Desktop 자체 재배포
- macOS installer
- image registry publish
- 자동 업데이트 channel

## Packaged datasource acceptance

- 격리된 PostgreSQL 테스트 DB에 실제 schema와 rows를 만든다.
- MindsDB `v26.1.0`을 app-owned Docker service와 offline image archive에 포함하고 Data Fabric은
  Docker network의 `http://mindsdb:47334`만 사용한다.
- 설치형 Gateway/Data Fabric 경로로 연결 검사, 등록, metadata 추출, sample query를 수행한다.
- MindsDB 연결과 app-owned Neo4j datasource registry가 함께 생성되어야 한다.
- stack 재시작 후 datasource registry와 조회 기능이 유지되어야 한다.
- 잘못된 접속정보는 registry를 남기지 않고 명확하게 실패해야 한다.
