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

## Requirements

- release는 dirty repository/submodule을 묵시적으로 패키징하지 않는다.
- image tag와 runtime manifest는 source commit으로 고정한다.
- 비밀번호와 API key는 image, installer, manifest, 로그에 포함하지 않는다.
- Docker stack은 외부에 Gateway, Analyzer MCP와 Neo4j Bolt만 bind하고 내부 서비스는
  전용 network에 둔다.
- host Architect API는 Docker 내부 Neo4j URI와 Gateway host port를 환경으로 받는다.
- release 실패는 non-zero exit이며 부분 산출물을 성공으로 보고하지 않는다.
- build와 runtime 검증은 생성 artifact 자체를 대상으로 한다.

## Non-goals

- Docker Desktop 자체 재배포
- macOS installer
- image registry publish
- 자동 업데이트 channel
