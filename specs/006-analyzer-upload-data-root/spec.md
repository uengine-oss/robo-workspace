# Analyzer server upload data root

## Goal

Standalone Analyzer 서버에서 브라우저 업로드, ANTLR 파싱, Analyzer 분석이 하나의
`project/data/{source,ddl,analysis}` workspace를 사용한다. CLI 단발 분석의 명시적
`--data-dir` 계약은 그대로 유지한다.

## Scenarios

1. **Given** sibling Analyzer `.env`에 과거 CLI corpus용 `ROBO_DATA_DIR`가 있다,
   **When** `robo.cmd up analyzer`로 서버를 시작한다,
   **Then** 서버의 ANTLR과 Analyzer는 둘 다 `${PROJECT_ROOT}/data`를 사용한다.
2. **Given** 브라우저가 `/antlr/fileUpload`로 파일을 올린다,
   **When** `/antlr/parsing`과 `/robo/analyze`가 이어진다,
   **Then** 세 단계가 같은 source·ddl·analysis 파일을 소비한다.
3. **Given** 운영자가 `scripts/analyze_data_dir.py --data-dir <corpus>`를 실행한다,
   **When** CLI 분석이 시작된다,
   **Then** 명시한 corpus를 사용하며 서버 profile 설정과 섞이지 않는다.

## Requirements

- Workspace가 서버 통합 data root의 단일 진실을 소유한다.
- ANTLR과 standalone Analyzer service는 같은 `ROBO_DATA_DIR=${PROJECT_ROOT}/data`를 받는다.
- `${PROJECT_ROOT}`는 실제 project root의 절대경로로 확장된다.
- repository `.env`나 상속 shell 값이 서버 upload workspace를 바꿀 수 없다.
- 실제 E2E는 upload payload, ANTLR source path, Analyzer start root를 같은 run에서 대조한다.
