# Robo Workspace

독립 Git 저장소로 구성된 Robo 서비스를 한 명령으로 준비·동기화·실행합니다. 소스 저장소를 합치거나 서브모듈로 중첩하지 않습니다.

## 처음 한 번

```cmd
robo.cmd setup analyzer
robo.cmd doctor analyzer
```

`setup`이 `.env.example`에서 로컬 `.env`를 처음 한 번 생성합니다. Neo4j와 LLM 등 비밀정보를 입력하세요. 공통 Neo4j 값은 Analyzer의 `ROBO_NEO4J_*`와 Catalog/Fabric의 `NEO4J_*` 양쪽에 전달됩니다.

## 실행

```cmd
robo.cmd up analyzer
robo.cmd status analyzer
robo.cmd logs analyzer
robo.cmd down analyzer
```

`analyzer` 프로필은 parser 8401, analyzer 5502, catalog 5503, fabric 8404, gateway 9000, frontend 3000을 실행합니다. 8004·8081이 Windows 예약 포트인 환경에서도 동작하도록 Gateway에는 실제 주소를 환경변수로 전달합니다.

## 저장소 동기화

```cmd
robo.cmd sync analyzer
```

변경 파일이 있는 저장소와 기본 브랜치가 아닌 저장소는 자동 변경하지 않습니다. 나머지만 `fetch` 후 `pull --ff-only`로 갱신합니다.

## 폴더 배치

기본 소스 위치는 이 저장소의 형제 `project/`입니다. 다른 위치는 환경변수로 지정할 수 있습니다.

```cmd
set ROBO_PROJECT_ROOT=D:\src\robo-projects
robo.cmd setup analyzer
```

로그와 PID 상태는 `robo-workspace/.robo/`에 저장됩니다. `down`은 이 실행기가 기록한 프로세스 트리만 종료합니다.

## 문제 해결

`doctor`가 실패하면 `[ACTION]`의 조치부터 수행합니다. 포트만 열려 있는 상태를 성공으로 보지 않고 각 서비스 HTTP health 응답까지 확인합니다.
