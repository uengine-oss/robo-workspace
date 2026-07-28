# Plan: Analyzer server upload data root

1. Workspace value 확장기에 `${PROJECT_ROOT}`를 추가한다.
2. standalone Analyzer와 ANTLR service에 같은 `${PROJECT_ROOT}/data`를 명시한다.
3. environment contract가 manifest 값과 절대경로 확장을 검증한다.
4. ANTLR `ParserWorkspace`가 `ROBO_DATA_DIR`를 명시적 shared-root 계약으로 소비하게 한다.
5. 두 service를 재시작하고 잘못 생성된 Neo4j graph만 초기화한다.
6. 기존 DataSource checkpoint에서 쇼핑몰 upload→parse→analyze를 한 번 실행해 경로를 대조한다.

## Non-goals

- `analyze_data_dir.py --data-dir` CLI 동작 변경
- 사용자 로컬 `.env` 변경
- Architect 기능 E2E
