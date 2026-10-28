# -*- coding: utf-8 -*-
"""SBOM 에서 **라이선스**를 모아 읽는다 — 오픈소스 검토에 낼 표.

## 왜 따로 있나

`sbom-release.py` 는 **무엇이 들어 있나**(구성품)와 **무엇이 남았나**(취약점)를
낸다. 받는 조직이 그 다음에 묻는 것은 **"어떤 라이선스냐"** 이고, 그 답은 이미
CycloneDX 안에 들어 있다. 사람이 json 3700줄을 세게 두지 않는다.

## 무엇을 내나

    <릴리스>/sbom/LICENSES.md   분류별 집계 + **검토할 목록**

## ⚠ 이 도구가 지키는 두 가지 — 둘 다 실제로 틀렸던 자리다

① **`LGPL` 을 `GPL` 로 세지 않는다.** 글자가 겹친다(`GPL-3` 이 `LGPL-3.0-only`
   안에 있다). 2026-10-29 에 그렇게 세어 보니 `psycopg`(실제 **LGPL-3.0**)가
   "강한 카피레프트" 로 잡혔다 — **거짓 경보 둘**. 약한 쪽을 **먼저** 가른다.

② **OS 꾸러미와 언어 꾸러미를 가른다.** 컨테이너 안의 데비안 패키지는 수천 개가
   GPL 이지만 그것은 **같이 담은 것(aggregation)** 이지 우리 코드에 **링크된 것**이
   아니다. 검토가 필요한 쪽은 `pypi`·`npm`·`maven`·`cargo` 처럼 **우리가 넣은**
   것이다. 둘을 같은 칸에 세면 "GPL 수천 건" 이라는 숫자가 나와 아무도 못 읽는다.

## 쓰는 법

    python robo-workspace/scripts/sbom-licenses.py <릴리스폴더>
"""
import collections
import glob
import io
import json
import os
import sys

# ⚠ **콘솔이 cp949 면 한글·기호 한 글자가 작업을 죽인다.** 이 저장소가 여러 번
#   밟았다 — 보고하는 `print` 가 보고하려던 실패를 죽인 적도 있다. 찍는 것 때문에
#   재는 것이 죽지 않도록 **출력을 UTF-8 로 돌리고, 못 찍는 글자는 바꿔 쓴다**.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

# OS 꾸러미 — 컨테이너에 **같이 담긴** 것. 링크가 아니다.
OS_TYPES = {"deb", "rpm", "apk"}

# 언어 꾸러미 — **우리가 넣은** 것. 검토는 여기만 본다.
LANG_TYPES = {"pypi", "npm", "maven", "cargo", "golang", "gem", "nuget",
              "composer", "conan", "swift", "pub", "hex", "cran"}

# ⚠ `generic` 은 언어 꾸러미가 **아니다.** bash·openssl·util-linux 처럼 purl 종류를
#   못 붙인 OS 바이너리가 여기로 온다. 언어 쪽에 섞으면 "라이선스를 못 읽은 언어
#   꾸러미 1249종" 같은 숫자가 나와 **읽을 수 없게 된다**(2026-10-29 실측).

# ⚠ 약한 쪽을 **먼저** 본다. 글자가 겹친다(`LGPL` 안에 `GPL` 이 있다).
WEAK_PREFIX = ("LGPL", "MPL", "EPL", "CDDL", "MS-RL", "Artistic", "CECILL-C")
STRONG_PREFIX = ("AGPL", "SSPL", "GPL", "EUPL", "OSL", "CPAL", "RPL", "CC-BY-SA")


def classify(identifier):
    """SPDX 식별자 하나를 세 칸 중 하나로 보낸다."""
    text = (identifier or "").strip()
    if not text:
        return "알 수 없음"
    upper = text.upper()
    for prefix in WEAK_PREFIX:
        if upper.startswith(prefix.upper()):
            return "약한 카피레프트"
    for prefix in STRONG_PREFIX:
        if upper.startswith(prefix.upper()):
            return "강한 카피레프트"
    return "허용적"


def licenses_of(component):
    out = []
    for entry in component.get("licenses") or []:
        lic = entry.get("license") or {}
        out.append(lic.get("id") or lic.get("name") or entry.get("expression") or "")
    return [x for x in out if x] or [""]


def purl_type(component):
    purl = component.get("purl") or ""
    if not purl.startswith("pkg:"):
        return "(purl 없음)"
    return purl[4:].split("/")[0].split("@")[0]


def main(release_dir):
    sbom_dir = os.path.join(release_dir, "sbom")
    files = sorted(glob.glob(os.path.join(sbom_dir, "*.cdx.json")))
    if not files:
        print("ERROR: no *.cdx.json under %s" % sbom_dir)
        return 1

    buckets = collections.Counter()      # (어디, 분류) -> 수
    by_license = collections.Counter()   # 식별자 -> 수
    review = []                          # 검토할 것 — 언어 꾸러미이면서 강한 쪽
    unknown = collections.Counter()      # 라이선스를 못 읽은 언어 꾸러미
    per_image = []

    for path in files:
        image = os.path.basename(path)[: -len(".cdx.json")]
        doc = json.load(io.open(path, encoding="utf-8"))
        comps = doc.get("components") or []
        counts = collections.Counter()
        for comp in comps:
            ptype = purl_type(comp)
            where = ("OS 꾸러미" if ptype in OS_TYPES
                     else "언어 꾸러미" if ptype in LANG_TYPES
                     else "그 밖")
            # 한 구성품에 여러 라이선스가 붙으면 **가장 센 것**으로 센다.
            kinds = [classify(x) for x in licenses_of(comp)]
            kind = ("강한 카피레프트" if "강한 카피레프트" in kinds
                    else "약한 카피레프트" if "약한 카피레프트" in kinds
                    else "허용적" if "허용적" in kinds
                    else "알 수 없음")
            buckets[(where, kind)] += 1
            counts[kind] += 1
            for one in licenses_of(comp):
                by_license[one or "(없음)"] += 1
            if where == "언어 꾸러미":
                if kind == "강한 카피레프트":
                    review.append((image, ptype, comp.get("name", "?"),
                                   comp.get("version", "?"), " · ".join(licenses_of(comp))))
                elif kind == "알 수 없음":
                    unknown[(ptype, comp.get("name", "?"))] += 1
        per_image.append((image, len(comps), counts))

    lines = [
        "# 라이선스 — %s" % os.path.basename(release_dir.rstrip("\\/")),
        "",
        "> `sbom/*.cdx.json` 에 든 라이선스를 모아 센 것이다. 뽑는 도구는",
        "> `robo-workspace/scripts/sbom-licenses.py` 이고, 원본은 `docker scout sbom` 이다.",
        ">",
        "> ⚠ **OS 꾸러미와 언어 꾸러미를 갈라 센다.** 컨테이너 안의 데비안 패키지는",
        "> 같이 담은 것이지 우리 코드에 링크된 것이 아니다. 검토가 필요한 쪽은",
        "> 우리가 넣은 `pypi`·`npm`·`maven`·`cargo` 다.",
        "",
        "## 한눈에",
        "",
        "| 어디 | 허용적 | 약한 카피레프트 | 강한 카피레프트 | 알 수 없음 |",
        "|---|---:|---:|---:|---:|",
    ]
    for where in ("언어 꾸러미", "OS 꾸러미", "그 밖"):
        lines.append("| %s | %d | %d | %d | %d |" % (
            where,
            buckets[(where, "허용적")],
            buckets[(where, "약한 카피레프트")],
            buckets[(where, "강한 카피레프트")],
            buckets[(where, "알 수 없음")],
        ))

    lang_total = sum(buckets[("언어 꾸러미", k)] for k in
                     ("허용적", "약한 카피레프트", "강한 카피레프트", "알 수 없음"))
    lang_unknown = buckets[("언어 꾸러미", "알 수 없음")]
    lang_read = lang_total - lang_unknown

    lines += ["", "## ⚠ 검토할 것 — **언어 꾸러미이면서 강한 카피레프트**", ""]
    if review:
        lines += ["| 이미지 | 종류 | 이름 | 판 | 라이선스 |", "|---|---|---|---|---|"]
        for row in sorted(set(review)):
            lines.append("| %s | %s | `%s` | %s | %s |" % row)
    else:
        lines.append("**읽은 것 중에는 없다** — AGPL·SSPL·GPL 계열이 하나도 없다.")
    lines += [
        "",
        "> ⚠ **이 말이 어디까지 닿는지 같이 읽는다.** 언어 꾸러미 **%d개** 중"
        " 라이선스를 읽을 수 있던 것은 **%d개**(%.0f%%)이고," % (
            lang_total, lang_read, (100.0 * lang_read / lang_total) if lang_total else 0.0),
        "> 나머지 **%d개는 못 읽었다.** 못 읽은 것은 \"허용적\" 이 아니라"
        " **모르는 것**이다 — 아래 목록을 본다." % lang_unknown,
    ]

    lines += ["", "## 라이선스를 못 읽은 언어 꾸러미", ""]
    if unknown:
        lines.append("%d종. 상위 15개:" % len(unknown))
        lines.append("")
        lines.append("```text")
        for (ptype, name), count in unknown.most_common(15):
            lines.append("%-8s %-40s %d" % (ptype, name[:40], count))
        lines.append("```")
        lines.append("")
        lines.append("> ⚠ **\"없다\" 가 아니라 \"못 읽었다\" 이다.** 심사에서 둘은 다르다 —")
        lines.append("> 필요하면 그 꾸러미의 배포 페이지에서 직접 확인한다.")
    else:
        lines.append("없다.")

    lines += ["", "## 이미지별", "", "| 이미지 | 구성품 | 허용적 | 약한 | 강한 | 모름 |",
              "|---|---:|---:|---:|---:|---:|"]
    for image, total, counts in per_image:
        lines.append("| %s | %d | %d | %d | %d | %d |" % (
            image, total, counts["허용적"], counts["약한 카피레프트"],
            counts["강한 카피레프트"], counts["알 수 없음"]))

    lines += ["", "## 많이 나온 라이선스 스무 개", "", "```text"]
    for name, count in by_license.most_common(20):
        lines.append("%-28s %d" % (str(name)[:28], count))
    lines += ["```", ""]

    out = os.path.join(sbom_dir, "LICENSES.md")
    io.open(out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")

    # 콘솔은 cp949 일 수 있다 — **ASCII 로만** 찍는다.
    print("images %d | components %d | review(strong, non-OS) %d | unknown(non-OS) %d"
          % (len(per_image), sum(t for _, t, _ in per_image), len(set(review)), len(unknown)))
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: python sbom-licenses.py <release-dir>")
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
