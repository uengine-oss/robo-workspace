# mindsdb 에서 **서버가 쓰지 않는 바이너리 하나**를 걷는다. 코드는 안 건드린다.
#
# ## 왜 우리가 손대나
#
# `mindsdb/mindsdb:v26.1.0` 은 `latest` 와 같은 **2026-04-23** 판이고, 공개 태그
# 872개에 더 새 것이 없다(2026-10-26 실측). 즉 **그 제품이 반년째 새 판을 내지
# 않아** 위에서 받을 수 있는 고친 판이 없다. 그래서 그 이미지가 **들고 있지
# 않아도 되는 것**만 우리가 걷는다.
#
# ## 무엇을 걷나 — 파일 하나
#
#   /venv/lib/python3.10/site-packages/iterfzf/fzf   3MB · go1.20.13
#
# **명령줄 퍼지 검색기**다. Go stdlib 1.20.13 의 **치명 6 · 고위험 36 = 42건**이
# 전부 이 파일 하나에서 나온다(전체 273건의 15%).
#
# 쓰는 곳을 전수로 봤다 — 요구하는 꾸러미는 `mind-castle` 하나이고, 그것을
# import 하는 코드는 `mind_castle/migration_tool.py` **한 파일**(대화형
# 마이그레이션 도구)뿐이다. 서버로 도는 경로(http API · mysql API)는 쓰지 않는다.
#
# ## ⚠ 지우는 것만으로는 **검사기 숫자가 안 준다**
#
# 조립된 파일 체계에서는 사라지지만 검사기가 **아래 레이어**에서 그 파일을 본다
# (2026-10-26 실측: 지우기만 하면 273 그대로). 그래서 이 이미지를 만든 뒤
# **반드시 평탄화**해야 한다 — `robo.ps1` 이 export → import 로 한다.
# 평탄화는 ENTRYPOINT·WORKDIR·EXPOSE·HEALTHCHECK·ENV 를 잃으므로 그쪽에서
# `docker import -c` 로 다시 선언한다. **둘은 함께 고쳐야 한다.**
#
# ## 안 한 것
#
# `-dev` 꾸러미 114개와 gcc·g++·make 도 남아 있다. 걷어 보니 **크기는 610MB
# 줄지만 취약점은 한 건도 안 줄었다** — 취약한 소스 꾸러미(`postgresql-17` 등)의
# **실행용 짝**(`libpq5`)이 남기 때문이다. 숫자를 못 줄이면서 상용 경로(데이터
# 소스 연결)의 위험만 더하므로 **하지 않았다**. 필요해지면 이 주석을 근거로
# 다시 판단한다.
FROM mindsdb/mindsdb:v26.1.0
USER root
RUN set -eu; \
    test -f /venv/lib/python3.10/site-packages/iterfzf/fzf; \
    rm -f /venv/lib/python3.10/site-packages/iterfzf/fzf; \
    python -c "import mindsdb, sys; print('import ok', sys.version.split()[0])"
