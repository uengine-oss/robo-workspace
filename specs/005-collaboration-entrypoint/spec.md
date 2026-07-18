# Spec: 협업자용 단일 Workspace 진입점

## 목적

Robo를 구성하는 독립 저장소와 여러 로컬 서비스를 협업자가 저장소별로 직접
조립하지 않고, `robo-workspace` 하나를 clone한 뒤 일관된 명령으로 준비·실행·종료할
수 있게 한다.

## 사용자 계약

- `robo-workspace`는 데모 전용 저장소가 아니라 로컬 통합 개발의 공용 진입점이다.
- 제품 저장소는 Workspace의 형제 `project/` 디렉터리에 각각 독립 Git 저장소로 둔다.
- Architect의 런타임 Analyzer는 형제 저장소에서 빌드한 federation remote를 사용한다.
- `analyzer` 프로필은 형제 Analyzer 본진 저장소를 사용한다.
- `architect-web`과 `architect-electron`은 Architect가 commit으로 고정한 중첩
  Analyzer 서브모듈을 사용한다.
- 일반 실행은 사용자 데이터나 Neo4j 내용을 초기화하지 않는다.
- E2E 격리 스택과 데이터 초기화는 Workspace 기본 명령과 분리하고, 특정 로컬
  폴더명을 하드코딩하지 않는다.

## 수용 조건

1. 새 협업자가 README의 clone → setup → `.env` → up 순서만으로 프로필을 실행할 수 있다.
2. `doctor`가 누락된 도구·저장소·환경값·포트를 구체적인 다음 행동과 함께 보고한다.
3. `architect-web`은 실제 API 포트와 Code/MCP backend URL을 동일하게 전달한다.
4. `down`은 Workspace가 기록한 프로세스만 종료하고, 강제 포트 종료는 명시적 옵션이다.
5. 일반 개발 프로필과 격리 E2E/영상 환경의 책임 경계가 문서에 명시된다.
