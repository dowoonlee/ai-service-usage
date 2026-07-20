#!/usr/bin/env python3
"""Swift 소스에서 펫 rarity/collection 맵을 파싱해 서버용 TS(pet_meta_gen.ts)를 생성.

서버 authoritative 스탯 계산(pvp_policy.ts)엔 펫별 rarity/collection 이 필요한데, 클라는 이를
Gacha.pool / PetCollection.members 에 하드코딩할 뿐 서버엔 없다. 이 스크립트가 그 진실을 TS로
포팅한다. 펫 추가·등급 변경 시 재실행:

    python3 scripts/gen_pet_meta.py

모든 PetKind 가 정확히 하나의 rarity·collection 에 속하는지 검증하고, 불일치 시 비-0 종료한다.
"""
import re, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources", "ClaudeUsage")
OUT = os.path.join(ROOT, "supabase", "functions", "_shared", "pet_meta_gen.ts")


def read(p):
    return open(os.path.join(SRC, p), encoding="utf-8").read()


def parse_groups(text, pattern):
    out = {}
    for m in re.finditer(pattern, text, re.S):
        key, arr = m.group(1), m.group(2)
        for k in re.findall(r"\.([A-Za-z0-9_]+)", arr):
            out.setdefault(key, []).append(k)
    return out


def main():
    # PetKind allCases
    ps = read("PetSprite.swift")
    block = re.search(r"enum PetKind[^{]*\{(.*?)\n\}", ps, re.S).group(1)
    kinds = []
    for line in block.splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[5:].split("//")[0].split(","):
            name = part.strip().split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z0-9_]+", name):
                kinds.append(name)

    gacha = read("Gacha.swift")
    pool = re.search(r"static let pool[^=]*=\s*\[(.*?)\n\s*\]\s*\n", gacha, re.S).group(1)
    kind_rarity = {k: r for r, ks in parse_groups(pool, r"\.(\w+):\s*\[(.*?)\]").items() for k in ks}

    pc = read("PetCollection.swift")
    kind_coll = {k: c for c, ks in parse_groups(pc, r"case \.(\w+):\s*return\s*\[(.*?)\]").items() for k in ks}

    kset = set(kinds)
    errs = []
    if len(kinds) != len(kset):
        errs.append("PetKind 중복 case")
    for k in kinds:
        if k not in kind_rarity:
            errs.append(f"rarity 누락: {k}")
        if k not in kind_coll:
            errs.append(f"collection 누락: {k}")
    for k in kind_rarity:
        if k not in kset:
            errs.append(f"rarity 여분(allCases 없음): {k}")
    for k in kind_coll:
        if k not in kset:
            errs.append(f"collection 여분: {k}")
    if errs:
        print("생성 실패 — 불일치:", *errs, sep="\n  ", file=sys.stderr)
        sys.exit(1)

    def ts_map(d):
        return "{\n" + "".join(f'  {k}: "{v}",\n' for k, v in sorted(d.items())) + "}"

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(
            "// AUTO-GENERATED — Swift 소스(Gacha.pool · PetCollection.members)에서 파싱. 직접 편집 금지.\n"
            f"// 재생성: scripts/gen_pet_meta.py (펫 추가/등급변경 시). {len(kinds)} kinds.\n"
            "// 서버 authoritative 스탯 계산에 필요(클라는 rarity를 하드코딩하지만 서버엔 없어서 포팅).\n\n"
            f"export const RARITY: Record<string,string> = {ts_map(kind_rarity)};\n\n"
            f"export const COLLECTION: Record<string,string> = {ts_map(kind_coll)};\n"
        )
    print(f"생성 완료: {OUT} ({len(kinds)} kinds)")


if __name__ == "__main__":
    main()
