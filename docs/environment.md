# Workspace 환경 설정

## 단일 입력

통합 개발 실행과 Electron 릴리스는 모두 `robo-workspace/.env`를 읽습니다.
처음에는 `.env.example`을 `.env`로 복사하고 비어 있는 비밀 값만 채웁니다.
서비스 저장소 안의 개별 `.env`는 Workspace 릴리스에 사용되지 않습니다.

```cmd
copy .env.example .env
notepad .env
```

필수 비밀 값은 다음 세 가지 용도로 나뉩니다.

- `ROBO_LLM_API_KEY`: Analyzer 생성 LLM
- `OPENAI_API_KEY`: Architect와 Catalog의 OpenAI-compatible client
- `ROBO_NEO4J_PASSWORD`: 개발 PC의 Neo4j 접속 전용

`LLM_API_KEY`, `ROBO_EMBED_API_KEY`, `ROBO_SEARCH_LLM_API_KEY`는 각 client를
별도 credential로 분리할 때만 채웁니다. 설치판 Neo4j 비밀번호는 Electron이 최초
실행 때 생성하므로 `.env`의 개발 비밀번호를 설치본에 넣지 않습니다.

## 서비스별 전달 범위

| 대상 | Workspace에서 전달하는 값 | 설치판이 직접 정하는 값 |
|---|---|---|
| Analyzer | `ROBO_LLM_*`, embedding/search, agent/pipeline, 로그 정책 | Neo4j, data dir, Catalog URL |
| Catalog | `LLM_*`, embedding, FK/metadata 정책 | Neo4j, Data Fabric URL, bind port |
| Data Fabric | query 정책, localhost 변환 정책 | Neo4j, MindsDB URL/host/port |
| Parser | `PARSER_*` 복구 정책 | data dir, bind port |
| Gateway | 선택적 Spring/Gateway 튜닝 | 모든 내부 서비스 URL |
| Architect | provider/model, change/ingestion/hybrid/wireframe 정책, DB 서버 authority origin | API port, Gateway/MCP URL, Neo4j |

정확한 허용 범위는 `release-environment.json`이 관리합니다. 릴리스 명령은 `.env`를
그대로 복사하지 않고 여섯 개의 최소 범위 snapshot으로 분리하며 각 SHA-256을
runtime manifest에 기록합니다.

## 두 LLM 토큰 설정

이름이 비슷하지만 소비자가 다릅니다.

- `LLM_MAX_OUTPUT_TOKENS`: Architect가 feature별 출력값에 적용하는 전역 상한
- `LLM_MAX_COMPLETION_TOKENS`: Catalog 설명 생성 request의 completion 상한

둘 중 하나로 통합된 것처럼 취급하면 한 서비스에는 설정이 적용되지 않습니다.
`.env.example`에는 현재 코드 기본값과 검증된 사내 GPU endpoint를 모두 기록합니다.

## 선택 설정과 topology 설정

`.env.example`의 활성 행은 검증된 기본 실행값입니다. `# KEY=value` 형태의 행은
코드가 지원하지만 평소에는 기본값 또는 Workspace가 주입하는 값을 사용하는 선택
설정입니다.

다음 값은 사용자 설정이 아니라 실행 topology이므로 설치판에 복사하지 않습니다.

- `ROBO_NEO4J_*`, `NEO4J_*`
- `ROBO_DATA_DIR`
- `ROBO_ANTLR_URL`, `ROBO_ANALYZER_URL`, `ROBO_CATALOG_URL`,
  `ROBO_DATA_FABRIC_URL`, `ROBO_ARCHITECT_URL`
- `MINDSDB_URL`, `MINDSDB_HOST`, `MINDSDB_API_PORT`
- Architect API port, Gateway/MCP URL

`ROBO_AUTHORITY_URL`은 DB central과 같은 사내망 DB 서버에서 실행하는 계정·프로젝트
gateway의 origin이다. `http://<DB_SERVER_PRIVATE_IP>:59020` 형태로 Architect snapshot에
포함한다. 사용자 PC와 DB 서버가 같은 사내망이라는 전제이며 인터넷 노출은 방화벽으로 막는다.

`ROBO_INGESTION_URL`은 기본 설치 topology에 포함하지 않는다. Analyzer, Parser, Fabric,
ingestion·탐색·승격은 사용자 PC의 Electron/Docker에서 실행한다. 별도 중앙 실행 서버를
운영하는 다른 배포에서만 수동으로 사용하는 선택 기능이다.

## 개발판과 POSCO 납품판

사내망 밖의 기능 안정화 기간에는 `internal-test` 개발판을 사용한다.

```dotenv
ROBO_RELEASE_CHANNEL=internal-test
AUTH_PROVIDER=none
AUTH_DEV_LOGIN_ENABLED=false
ROBO_AUTHORITY_URL=
```

개발 로그인은 설치 자산에 굽지 않는다. 릴리스 검사가
`AUTH_DEV_LOGIN_ENABLED=true` 패키징을 거절하며, 시험 PC의 사용자 설정에서만 켠다.
기본 시험 계정은 `test/test`이고 loopback 요청만 허용한다. ingestion은 로컬 실행이다.

기능 보정과 회귀 검증이 끝난 뒤에만 POSCO 납품판을 별도로 만든다.

```dotenv
ROBO_RELEASE_CHANNEL=delivery
AUTH_PROVIDER=swp
AUTH_DEV_LOGIN_ENABLED=false
ROBO_AUTHORITY_URL=http://<DB_SERVER_PRIVATE_IP>:59020
```

납품판은 실제 사내망에서 SWP, DB 서버 사내 IP, 방화벽과 계정 승인 흐름을 검증해야 한다.
개발판의 사용자 환경 override가 남아 있으면 Electron의 delivery posture 검사가 기동을 막아야 한다.

## 회귀 검증

`tests/environment-catalog.ps1`은 실제 Analyzer, Catalog, Data Fabric, Parser,
Gateway, Architect 소스가 읽는 환경변수와 `.env.example`을 대조합니다. 서비스
checkout이 있는 개발 환경에서는 새 환경변수가 템플릿에 누락되면 실패합니다.
또한 중요 설정이 올바른 release snapshot에 들어가고 Neo4j/MindsDB topology가
빠지는지 검사합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\environment-catalog.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\environment-contract.ps1
```
