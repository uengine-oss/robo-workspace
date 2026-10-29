# -*- coding: utf-8 -*-
"""릴리스의 구성품 목록(SBOM)을 **두 형식**(CycloneDX · SPDX)으로 뽑는다.

## 왜 있나

납품물에 **무엇이 들어 있는지** 목록으로 내야 한다(ENT-SEC-003). 이미지 **열
개**를 각각 뽑고, 하나로 묶은 색인을 같이 낸다.

라이선스는 **따로 센다** — `sbom-licenses.py` 가 여기서 나온 `*.cdx.json` 을 읽어
`LICENSES.md` 를 만든다.

## 무엇을 내나

    <릴리스>/sbom/<이미지>.cdx.json   이미지마다 하나 (CycloneDX 1.x · JSON)
    <릴리스>/sbom/<이미지>.spdx.json  이미지마다 하나 (SPDX · JSON)
    <릴리스>/sbom/INDEX.md            사람이 먼저 읽는 것 — 무엇이·몇 개·무엇이 남았나
    <릴리스>/sbom/SHA256SUMS          위 파일들의 지문

⚠ **남은 취약점은 글로 박지 않고 그 자리에서 센다**(2026-10-23). 박아 두면
거둔 뒤에도 납품물이 "아직 남았다" 고 말한다 — 실제로 10-22 판이 그랬다.
자세한 까닭은 `run_cves` 의 머리말.

⚠ **우리가 굽는 것과 밖에서 당겨 오는 것을 가른다.** 열 개는 릴리스 tar 에
구워 담고, `pdf2bpmn` 하나만 ghcr 에서 당겨 온다. 소유가 아니라 포장 방식의
차이다 — `pdf2bpmn` 도 우리 소스다.
⚠ **2026-10-27 부터 남의 제품은 하나도 없다.** 마지막 하나였던 `mindsdb` 를
걷어냈다(그것 혼자 231건을 들고 있었다).

⚠ 못 읽은 이미지가 하나라도 있으면 **실패로 낸다.** 빠진 채로 목록을 내면
"없다" 와 "못 읽었다" 를 심사에서 가를 수 없다.
"""
import hashlib
import io
import json
import os
import re
import subprocess
import sys

# ⚠ **콘솔이 cp949 면 한글·기호 한 글자가 작업을 죽인다.** 2026-10-29 에 실제로
#   났다 — SBOM 하나가 실패해서 그 사실을 찍으려던 줄(⚠)이 UnicodeEncodeError
#   로 죽어, **무엇이 실패했는지도 못 본 채** 전체가 섰다. 보고하는 길이 재는 길을
#   죽이면 안 된다. 출력을 UTF-8 로 돌리고 못 찍는 글자는 바꿔 쓴다.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

# ⚠ 대상은 **매니페스트에서** 끌어온다 — 리터럴 목록을 두지 않는다.
#
# 예전에는 enterprise 이미지 아홉이 여기 박혀 있었다. 그래서 lite 판(일곱)에
# 돌리면 없는 `robo-authority`·`open-pencil` 을 당기려다 "Pull failed" 로 죽고
# **SBOM 폴더가 아예 안 만들어졌다**(2026-10-29 실측). 매니페스트의 `images` 가
# "그 릴리스에 무엇이 들었나" 의 권위다 — 거기서 읽으면 두 줄기 모두 맞고,
# 서비스를 더하거나 뺄 때 이 파일을 또 고칠 일이 없다.
OURS_PREFIX = "uengine/"


# 두 형식을 **같이** 낸다 (2026-10-22).
#
# 사용자는 CycloneDX 를 요청했고, `가이드/구조.md` 는 SPDX 라고 적혀 있었다.
# 어느 쪽이 맞느냐를 문서로 다투는 것보다 **둘 다 내는 쪽**이 싸다 — 받는 조직이
# 쓰는 도구에 맞춰 고르면 된다. 같은 이미지에서 같은 날 뽑은 것이라 내용은 같다.
FORMATS = [
    ("cyclonedx", "cdx.json", "components"),
    ("spdx", "spdx.json", "packages"),
]


def run_sbom(fmt, ref, out_path, count_key):
    """한 이미지의 SBOM 을 한 형식으로 파일에 받는다."""
    try:
        p = subprocess.run(
            ["docker", "scout", "sbom", "--format", fmt, "-o", out_path, ref],
            capture_output=True, text=True, timeout=1800,
            encoding="utf-8", errors="replace")
    except Exception as exc:
        return None, "실행 실패: %s" % type(exc).__name__
    if p.returncode != 0 or not os.path.exists(out_path):
        return None, (p.stderr or p.stdout or "").strip().splitlines()[-1:] or ["알 수 없는 실패"]
    try:
        doc = json.load(io.open(out_path, encoding="utf-8"))
    except Exception as exc:
        return None, "JSON 이 아니다: %s" % exc
    return len(doc.get(count_key) or []), None


def run_cves(ref):
    """한 이미지의 **치명+고위험** 건수와 취약한 꾸러미들을 센다.

    ⚠ 이 함수가 있는 까닭. 전에는 "무엇이 왜 남았나" 를 **이 스크립트에 글로
    박아** 뒀다. 그래서 10-22 에 gateway 치명 2 와 pdf2bpmn 고위험 1 을 거둔
    뒤에도 납품물의 `INDEX.md` 는 **여전히 3건이 남았다고 적고 있었다.**
    취약점이 없는데 납품물이 "있다" 고 말하는 것은, 있는 걸 빠뜨리는 것만큼
    나쁘다 — 심사에서 고친 것을 안 고쳤다고 보고하는 셈이다.

    그래서 **세는 일과 쓰는 일을 같은 순간에** 둔다. 사람이 고치는 걸 잊을
    자리를 없앤다.

    ⚠ 읽을 줄은 `vulnerabilities │` 가 있는 **요약줄 하나**다. 꾸러미 줄도
    `2C 10H` 와 같은 모양이라 마지막 줄을 집으면 **꾸러미 하나의 수**를 전체로
    읽는다 — 10-22 에 실제로 그래서 mindsdb 를 257 대신 1 로 봤다.
    """
    try:
        p = subprocess.run(
            ["docker", "scout", "cves", "--only-severity", "critical,high", ref],
            capture_output=True, text=True, timeout=1800,
            encoding="utf-8", errors="replace")
    except Exception as exc:
        return None, None, "실행 실패: %s" % type(exc).__name__
    out = (p.stdout or "") + "\n" + (p.stderr or "")
    crit = high = None
    for line in out.splitlines():
        if "vulnerabilities" in line and "│" in line:
            m = re.search(r"(\d+)C\s+(\d+)H", line)
            if m:
                crit, high = int(m.group(1)), int(m.group(2))
                break
    if crit is None:
        return None, None, "요약줄을 못 찾았다"
    # 꾸러미 줄: "   2C     0H     0M     0L  org.springframework/spring-webflux 6.2.19"
    pkgs = []
    for line in out.splitlines():
        m = re.match(r"\s+(\d+)C\s+(\d+)H\s+\d+M\s+\d+L\s+(\S+)\s+(\S+)\s*$", line)
        if m and (int(m.group(1)) or int(m.group(2))):
            pkgs.append("%s %s — 치명 %s · 고위험 %s"
                        % (m.group(3), m.group(4), m.group(1), m.group(2)))
    return crit, high, pkgs


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_docker():
    """도커가 살아 있나 — **재기 전에** 본다.

    ⚠ 2026-10-29 실측: Docker Desktop 이 꺼져 있는데 그대로 돌렸더니 이미지
    **스무 개가 전부** `x Pull failed` 로 떨어졌다. scout 는 로컬에서 못 찾으면
    레지스트리로 가고, 거기도 못 가면 그 문구를 낸다 — 즉 **"도커가 꺼졌다" 가
    "당기기 실패" 로 보인다.** 그 말을 본 사람은 망·권한·토큰을 뒤지게 된다.
    """
    try:
        probe = subprocess.run(["docker", "info", "--format", "{{.ServerVersion}}"],
                               capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
    except OSError as exc:
        return "도커 명령을 찾을 수 없다: %s" % exc
    if probe.returncode != 0:
        first = (probe.stderr or probe.stdout or "").strip().splitlines()
        return ("도커에 닿지 못했다 — Docker Desktop 이 떠 있는지 먼저 본다. %s"
                % (first[0][:160] if first else ""))
    return None


def main(release_dir):
    manifest = os.path.join(release_dir, "runtime-manifest.json")
    if not os.path.exists(manifest):
        print("매니페스트가 없다: %s" % manifest)
        return 1
    # **재기 전에** 도구가 살아 있는지 본다 — 아니면 엉뚱한 실패가 스무 줄 난다.
    trouble = ensure_docker()
    if trouble:
        print(trouble)
        return 1
    images = (json.load(io.open(manifest, encoding="utf-8")).get("images") or {})
    if not images:
        print("매니페스트에 images 가 없다: %s" % manifest)
        return 1

    # 우리가 굽는 것(`uengine/…`)과 밖에서 당겨 오는 것을 **나눠서** 센다 —
    # 색인이 그 둘을 따로 적는다. 남의 제품은 2026-10-27 에 없어졌다(mindsdb
    # 하나가 취약점 231건이었다). 지금 당겨 오는 것은 `pdf2bpmn` 뿐이다.
    # ⚠ 이름 규칙을 **가른다.** 파일 이름이 바뀌면 가이드·색인과 어긋난다.
    #    우리 것    참조의 저장소 이름 → `ontological-db` · `robo-analyzer` …
    #               (매니페스트 열쇠는 `graphDb` 꼴이라 쓰면 전부 바뀐다)
    #    당겨 오는 것  **매니페스트 열쇠** → `pdf2bpmn`
    #               (참조에서 뽑으면 `process-gpt-bpmn-extractor` 가 된다)
    #    두 번 헛짚고 나서 이렇게 갈랐다(2026-10-29).
    targets, seen = [], set()
    for key, ref in images.items():
        if not isinstance(ref, str) or not ref or ref in seen:
            continue
        seen.add(ref)
        if ref.startswith(OURS_PREFIX):
            targets.append(("ours", ref.rsplit("/", 1)[-1].split(":", 1)[0], ref))
        else:
            targets.append(("pulled", str(key), ref))
    targets.sort(key=lambda t: (t[0] != "ours", t[1]))
    print("대상 %d장 (우리 %d · 당겨 오는 %d)" % (
        len(targets),
        sum(1 for t in targets if t[0] == "ours"),
        sum(1 for t in targets if t[0] == "pulled")))

    out_dir = os.path.join(release_dir, "sbom")
    os.makedirs(out_dir, exist_ok=True)

    rows, failed, files = [], [], []
    for kind, label, ref in targets:
        counts = {}
        for fmt, ext, count_key in FORMATS:
            path = os.path.join(out_dir, "%s.%s" % (label, ext))
            n, err = run_sbom(fmt, ref, path, count_key)
            if n is None:
                failed.append(("%s (%s)" % (label, fmt), err))
                print("  %-22s %-10s ⚠ %s" % (label, fmt, err))
            else:
                counts[fmt] = n
                files.append(os.path.basename(path))
        if len(counts) != len(FORMATS):
            continue
        # 같은 이미지에서 **구성품과 취약점을 함께** 센다 — 둘이 다른 순간에서
        # 나오면 색인의 글과 숫자가 어긋난다(이 파일 머리의 `run_cves` 참고).
        crit, high, pkgs = run_cves(ref)
        if crit is None:
            failed.append(("%s (cves)" % label, pkgs))
            print("  %-22s cves       ⚠ %s" % (label, pkgs))
            continue
        rows.append((kind, label, ref, counts["cyclonedx"], crit, high, pkgs))
        print("  %-22s cyclonedx %5d · spdx %5d · 취약 %dC %dH" %
              (label, counts["cyclonedx"], counts["spdx"], crit, high))

    if failed:
        print("⚠ **못 읽은 것 %d개** — 목록을 내지 않는다" % len(failed))
        return 1

    sums = os.path.join(out_dir, "SHA256SUMS")
    with io.open(sums, "w", encoding="utf-8", newline="\n") as fh:
        for fname in sorted(files):
            fh.write("%s  %s\n" % (sha256(os.path.join(out_dir, fname)), fname))

    write_index(out_dir, release_dir, rows)
    print("SBOM %d개 · 색인과 지문까지: %s" % (len(rows), out_dir))
    return 0


def write_index(out_dir, release_dir, rows):
    total = sum(r[3] for r in rows)
    lines = [
        "# 구성품 목록(SBOM) — %s" % os.path.basename(release_dir.rstrip("\\/")),
        "",
        "> **두 형식을 같이 낸다** — 받는 조직이 쓰는 도구에 맞춰 고르면 된다.",
        "> 같은 이미지에서 같은 날 뽑은 것이라 내용은 같다.",
        ">",
        "> ```text",
        "> <이름>.cdx.json    CycloneDX 1.5",
        "> <이름>.spdx.json   SPDX",
        "> SHA256SUMS         위 파일 전부의 지문",
        "> ```",
        ">",
        "> 도구는 `docker scout sbom` · 뽑는 스크립트는",
        "> `robo-workspace/scripts/sbom-release.py` (굽기와 별개로 돌린다).",
        "",
        "구성품 **%d개** · 이미지 **%d개** · 파일 **%d개**." % (total, len(rows), len(rows) * 2),
        "",
        "## 우리가 굽는 이미지",
        "",
        "| 이미지 | 구성품 |",
        "|---|---:|",
    ]
    for kind, label, _ref, n, _c, _h, _p in rows:
        if kind == "ours":
            lines.append("| %s | %d |" % (label, n))
    lines += [
        "",
        "## 밖에서 당겨 오는 이미지",
        "",
        "| 이미지 | 구성품 | 무엇인가 |",
        "|---|---:|---|",
    ]
    for kind, label, _ref, n, _c, _h, _p in rows:
        if kind == "pulled":
            lines.append("| %s | %d | **우리 소스**다(uengine-oss). 소유가 아니라 "
                         "포장이 다르다 — 이 하나만 ghcr 에서 당겨 온다 |" % (label, n))
        elif kind == "third":
            lines.append("| %s | %d | **남의 제품**. 이 목록에서 유일하다 |"
                         % (label, n))
    # ── 점검 결과 — **이 실행에서 잰 값으로만 쓴다** ────────────────────────
    #
    # 전에는 아래 글이 코드에 박혀 있었다. 그래서 거둔 뒤에도 납품물이 "아직
    # 남았다" 고 말했다(10-22). 이제 글과 숫자가 **같은 실행**에서 나온다.
    ours_total = sum(r[4] + r[5] for r in rows if r[0] in ("ours", "pulled"))
    third_total = sum(r[4] + r[5] for r in rows if r[0] == "third")
    clean = [r[1] for r in rows if (r[4] + r[5]) == 0]
    dirty = [r for r in rows if (r[4] + r[5]) > 0]

    lines += [
        "",
        "## 점검에서 남은 것 — **이 목록을 뽑은 날 잰 값**",
        "",
        "> 도구 `docker scout cves --only-severity critical,high`.",
        "> **구성품과 같은 실행에서 쟀다** — 글과 숫자가 어긋날 수 없다.",
        "",
        "```text",
        "우리 것(굽는 9 + 당겨 오는 1)   **%d건**" % ours_total,
        "남의 제품                        **없다** (2026-10-27 에 걷어냈다)",
        "합계                            **%d건**" % (ours_total + third_total),
        "```",
        "",
    ]
    if dirty:
        # 꾸러미를 **다 싣지 않는다.** mindsdb 하나가 55개를 내는데 한 칸에 다
        # 넣으면 표가 읽히지 않는다(10-23 에 실제로 그랬다). 큰 것 몇 개로
        # 성격을 보이고, 전부는 옆의 SBOM·CVE 파일이 들고 있다.
        TOP = 8
        lines += ["| 이미지 | 치명 | 고위험 | 큰 꾸러미 (치명+고위험 순) |",
                  "|---|---:|---:|---|"]
        for _k, label, _ref, _n, crit, high, pkgs in dirty:
            if not isinstance(pkgs, list) or not pkgs:
                lines.append("| %s | %d | %d | — |" % (label, crit, high))
                continue
            head = pkgs[:TOP]
            rest = len(pkgs) - len(head)
            what = "<br>".join(head)
            if rest > 0:
                what += "<br>… 그 밖 **%d개**" % rest
            lines.append("| %s | %d | %d | %s |" % (label, crit, high, what))
        lines += ["", "> 꾸러미는 큰 것 %d개만 적는다 — 전부는 같은 폴더의 "
                  "`<이름>.cdx.json` · `<이름>.spdx.json` 에 있다." % TOP]
        lines += [
            "",
            "⚠ **왜 남았는지는 숫자가 말해 주지 않는다.** 사유는 사람이 적는다 —",
            "`electron-test/` 의 그날 `취약점-조치-*.md` 가 그 자리다.",
            "",
        ]
    else:
        lines += ["**남은 것이 없다** — 위 이미지 전부 치명·고위험 0건이다.", ""]
    if clean:
        lines += ["0건인 이미지 **%d개**: %s" % (len(clean), " · ".join(clean)), ""]
    lines += [
        "⚠ 취약점 DB 는 **날마다 움직인다.** 이 목록은 뽑은 날의 사진이다 —",
        "다시 물어야 할 때는 같은 날·같은 도구로 다시 잰다. **0 은 \"오늘 잰",
        "범위에서 0\" 이지 \"앞으로도 0\" 이 아니다.**",
        "",
    ]
    io.open(os.path.join(out_dir, "INDEX.md"), "w", encoding="utf-8",
            newline="\n").write("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
