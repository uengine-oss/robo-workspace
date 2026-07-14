# Analyzer workspace launcher

## Outcome

한 번의 setup으로 독립 저장소들을 준비하고 Analyzer 전체를 안전하게 실행·관찰·종료한다.

## Contract

- `setup analyzer`: 누락 저장소 clone, Python/Node 의존성 준비
- `sync analyzer`: dirty 또는 비기본 브랜치는 보존, clean 기본 브랜치만 fast-forward
- `doctor analyzer`: 도구·저장소·의존성·환경·Neo4j·포트 진단
- `up analyzer`: 6개 서비스 기동 후 HTTP health 전수 확인, 실패 시 소유 프로세스 정리
- `status/logs/down`: 기록된 PID만 대상으로 상태·로그·종료 제공
- 비밀정보를 저장·로그·커밋하지 않는다.

## Scenarios

- 깨끗한 Windows 환경에서 setup 후 실행할 수 있다.
- 저장소에 WIP가 있으면 sync가 건드리지 않는다.
- 포트 충돌, 의존성 누락, 서비스 조기 종료가 명확히 실패한다.
- down 후 실행기가 소유한 자식 프로세스가 남지 않는다.

