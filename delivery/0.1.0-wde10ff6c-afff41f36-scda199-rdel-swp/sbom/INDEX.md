# 구성품 목록(SBOM) — 0.1.0-wde10ff6c-afff41f36-scda199-rdel-swp

> **두 형식을 같이 낸다** — 받는 조직이 쓰는 도구에 맞춰 고르면 된다.
> 같은 이미지에서 같은 날 뽑은 것이라 내용은 같다.
>
> ```text
> <이름>.cdx.json    CycloneDX 1.5
> <이름>.spdx.json   SPDX
> SHA256SUMS         위 파일 전부의 지문
> ```
>
> 도구는 `docker scout sbom` · 뽑는 스크립트는
> `robo-workspace/scripts/sbom-release.py` (굽기와 별개로 돌린다).

구성품 **3733개** · 이미지 **10개** · 파일 **20개**.

## 우리가 굽는 이미지

| 이미지 | 구성품 |
|---|---:|
| ontological-bolt | 136 |
| ontological-db | 187 |
| open-pencil | 190 |
| robo-analyzer | 271 |
| robo-antlr-parser | 283 |
| robo-api-gateway | 301 |
| robo-authority | 784 |
| robo-data-catalog | 238 |
| robo-data-fabric | 196 |

## 밖에서 당겨 오는 이미지

| 이미지 | 구성품 | 무엇인가 |
|---|---:|---|
| pdf2bpmn | 1147 | **우리 소스**다(uengine-oss). 소유가 아니라 포장이 다르다 — 이 하나만 ghcr 에서 당겨 온다 |

## 점검에서 남은 것 — **이 목록을 뽑은 날 잰 값**

> 도구 `docker scout cves --only-severity critical,high`.
> **구성품과 같은 실행에서 쟀다** — 글과 숫자가 어긋날 수 없다.

```text
우리 것(굽는 9 + 당겨 오는 1)   **0건**
남의 제품                        **없다** (2026-10-27 에 걷어냈다)
합계                            **0건**
```

**남은 것이 없다** — 위 이미지 전부 치명·고위험 0건이다.

0건인 이미지 **10개**: ontological-bolt · ontological-db · open-pencil · robo-analyzer · robo-antlr-parser · robo-api-gateway · robo-authority · robo-data-catalog · robo-data-fabric · pdf2bpmn

⚠ 취약점 DB 는 **날마다 움직인다.** 이 목록은 뽑은 날의 사진이다 —
다시 물어야 할 때는 같은 날·같은 도구로 다시 잰다. **0 은 "오늘 잰
범위에서 0" 이지 "앞으로도 0" 이 아니다.**
