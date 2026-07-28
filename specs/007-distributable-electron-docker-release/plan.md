# Plan: Distributable Electron Docker release

## Current flow

`robo.cmd build architect-electron installer`는 frontend와 Electron shell만 패키징한다.
실행 시 Workspace가 개발 checkout의 Python/Java 서비스와 외부 Neo4j를 별도로 띄운다.

## Target flow

1. pinned Architect submodule source로 service images를 build한다.
2. parser/gateway 독립 repository image를 같은 release tag로 build한다.
3. Neo4j LTS image를 포함해 `docker save` offline archive를 만든다.
4. relocatable Python에 Architect dependencies와 runtime source를 설치한다.
5. frontend/Electron을 빌드하고 Compose, image archive, runtime manifest를 extraResources로 넣는다.
6. NSIS installer와 SHA-256 manifest를 `_releases/<version>/`에 복사한다.
7. packaged runtime manifest, image archive content, installer 존재와 checksum을 검증한다.

## Ownership

- `robo-workspace`: release orchestration, source cleanliness, image build/save, final manifest.
- `robo-architect/desktop`: bundled runtime layout, Docker stack lifecycle, local API lifecycle,
  Electron packaging.
- service repositories: their own Docker image build contract.

## Rollback

기존 `build architect-electron installer` 개발 패키징은 유지한다. 신규 `release`만
Docker-managed distributable path를 사용한다.

## Verification

- Workspace environment/process tests
- release script contract tests with command stubs
- Electron TypeScript build and desktop unit tests
- Compose config validation
- Docker image build
- packaged app startup: image load → container health → local API health → UI
- app exit: owned containers/process 0, Neo4j volume preserved

