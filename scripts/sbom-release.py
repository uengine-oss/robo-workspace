# -*- coding: utf-8 -*-
"""릴리스의 구성품 목록(SBOM)을 **CycloneDX** 로 뽑는다.

## 왜 있나

납품물에 **무엇이 들어 있는지** 목록으로 내야 한다(ENT-SEC-003). 이미지 열한
개를 각각 뽑고, 하나로 묶은 색인을 같이 낸다.

## 무엇을 내나

    <릴리스>/sbom/<이미지>.cdx.json   이미지마다 하나 (CycloneDX 1.x · JSON)
    <릴리스>/sbom/INDEX.md            사람이 먼저 읽는 것 — 무엇이·몇 개·왜 남았나
    <릴리스>/sbom/SHA256SUMS          위 파일들의 지문

⚠ **우리가 굽는 것과 밖에서 당겨 오는 것을 가른다.** 열 개는 릴리스 tar 에
구워 담고, `pdf2bpmn` 하나만 ghcr 에서 당겨 온다. 소유가 아니라 포장 방식의
차이다 — `pdf2bpmn` 도 우리 소스다. **남의 것은 `mindsdb` 하나뿐이다.**

⚠ 못 읽은 이미지가 하나라도 있으면 **실패로 낸다.** 빠진 채로 목록을 내면
"없다" 와 "못 읽었다" 를 심사에서 가를 수 없다.
"""
import hashlib
import io
import json
import os
import subprocess
import sys

OURS = ["ontological-db", "ontological-bolt", "robo-analyzer", "robo-antlr-parser",
        "robo-api-gateway", "robo-authority", "robo-data-catalog",
        "robo-data-fabric", "open-pencil"]


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


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(release_dir):
    manifest = os.path.join(release_dir, "runtime-manifest.json")
    if not os.path.exists(manifest):
        print("매니페스트가 없다: %s" % manifest)
        return 1
    images = (json.load(io.open(manifest, encoding="utf-8")).get("images") or {})
    tag = None
    for name in OURS:
        for v in images.values():
            if isinstance(v, str) and ("/" + name + ":") in ("/" + v):
                tag = v.split(":", 1)[1]
    # 우리 이미지는 전부 같은 릴리스 태그를 쓴다 — 매니페스트에서 하나만 읽으면 된다.
    if not tag:
        tag = os.path.basename(release_dir.rstrip("\\/"))

    targets = [("ours", n, "uengine/%s:%s" % (n, tag)) for n in OURS]
    for key, label in (("pdf2bpmn", "pdf2bpmn"), ("mindsdb", "mindsdb")):
        ref = images.get(key)
        if ref:
            targets.append(("pulled" if key == "pdf2bpmn" else "third", label, ref))

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
        if len(counts) == len(FORMATS):
            rows.append((kind, label, ref, counts["cyclonedx"], label))
            print("  %-22s cyclonedx %5d · spdx %5d" %
                  (label, counts["cyclonedx"], counts["spdx"]))

    if failed:
        print("⚠ **못 뽑은 것 %d개** — 목록을 내지 않는다" % len(failed))
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
    for kind, label, _ref, n, _f in rows:
        if kind == "ours":
            lines.append("| %s | %d |" % (label, n))
    lines += [
        "",
        "## 밖에서 당겨 오는 이미지",
        "",
        "| 이미지 | 구성품 | 무엇인가 |",
        "|---|---:|---|",
    ]
    for kind, label, _ref, n, _f in rows:
        if kind == "pulled":
            lines.append("| %s | %d | **우리 소스**다(uengine-oss). 소유가 아니라 "
                         "포장이 다르다 — 이 하나만 ghcr 에서 당겨 온다 |" % (label, n))
        elif kind == "third":
            lines.append("| %s | %d | **남의 제품**. 이 목록에서 유일하다 |"
                         % (label, n))
    lines += [
        "",
        "## 점검에서 남은 것과 그 이유",
        "",
        "> 숫자의 권위는 `electron-test/2026-10-22/취약점-조치-2026-10-22.md` 다.",
        "",
        "```text",
        "robo-api-gateway  **치명 2**  spring-webflux 6.2.19 — 6.2 줄에 고친 판이",
        "                             없다(Central 확인). Boot 4 로 가면 범위를",
        "                             벗어나지만 Spring Cloud 가 마일스톤뿐이라",
        "                             납품물에 실을 수 없다. 정식판을 기다린다",
        "pdf2bpmn          **고위험 1** protobuf 5.29.5 — 고친 판은 있으나 올리면",
        "                             SDK 가 끌려가 `a2a_server` 가 죽고, 파이썬을",
        "                             올리면 다른 것이 더 늘어난다(둘 다 실측)",
        "mindsdb           **257**     최신판이라 올릴 판이 없다. 쓰기로 한",
        "                             사용자 결정이다 — 근거 문서는 ISS-38",
        "그 밖의 우리 이미지 여덟      **0건**",
        "```",
        "",
        "⚠ 취약점 DB 는 **날마다 움직인다.** 이 목록은 뽑은 날의 사진이다 —",
        "다시 물어야 할 때는 같은 날·같은 도구로 다시 잰다.",
        "",
    ]
    io.open(os.path.join(out_dir, "INDEX.md"), "w", encoding="utf-8",
            newline="\n").write("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
