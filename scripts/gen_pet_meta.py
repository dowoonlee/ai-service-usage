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

    # unique 고유기(Epic+ per-kind) — PetSkills.uniqueTable 블록에서 .kind: ("id", "name") 파싱.
    sk = read("PetSkills.swift")
    ublock = re.search(r"static let uniqueTable[^=]*=\s*\[(.*?)\n\s*\]", sk, re.S)
    if not ublock:   # fail-closed: 앵커 미스매치 시 조용히 빈 맵 생성하지 않는다.
        print("생성 실패 — PetSkills.uniqueTable 블록 파싱 실패(정규식 앵커 확인)", file=sys.stderr)
        sys.exit(1)
    kind_unique = {}
    for m in re.finditer(r'\.(\w+):\s*\("([^"]+)",\s*"([^"]+)"\)', ublock.group(1)):
        kind_unique[m.group(1)] = [m.group(2), m.group(3)]

    # ── 베이스 스킬 배정(카탈로그 다양화) — Swift 배정 공식을 재현해 resolved 테이블을 emit.
    # 서버는 공식을 모른 채 조회만 한다. 이 py 재현이 Swift(assignIndex 파생)와 드리프트하면
    # PARITYBASE 골든(deno)이 잡는다. 설계: docs/plans/skill-catalog-expansion.md §4.
    gblock = re.search(r"static let genericPool[^=]*=\s*\[(.*?)\n\s*\]", sk, re.S)
    tblock = re.search(r"static let typeSharedPools[^=]*=\s*\[(.*?)\n\s*\]\n", sk, re.S)
    stride_m = re.search(r"static let genericStride\s*=\s*(\d+)", sk)
    if not gblock or not tblock or not stride_m:
        print("생성 실패 — genericPool/typeSharedPools/genericStride 파싱 실패(정규식 앵커 확인)", file=sys.stderr)
        sys.exit(1)
    generic_pool = re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', gblock.group(1))
    stride = int(stride_m.group(1))
    type_pools = {}
    for m in re.finditer(r"\.(\w+):\s*\[(.*?)\]", tblock.group(1), re.S):
        type_pools[m.group(1)] = re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', m.group(2))

    # 컬렉션 선언 순서(= Swift PetCollection.allCases 순서) — enum 케이스 선언에서 파싱.
    # switch 안의 `case .x`는 점(.) 접두라 매치되지 않는다.
    pc_enum = re.search(r"enum PetCollection\b[^{]*\{(.*?)\n\}", pc, re.S).group(1)
    coll_order = re.findall(r"\n    case (\w+)", pc_enum)

    # 컬렉션 → 배틀타입 (PetBattleStats.swift의 switch에서 파싱 — 타입 풀 선택에 필요).
    pbs = read("PetBattleStats.swift")
    bt_switch = re.search(r"var battleType: BattleType \{\s*switch self \{(.*?)\n        \}", pbs, re.S).group(1)
    coll_type = {}
    for m in re.finditer(r"case ([^:]+):\s*\n\s*return \.(\w+)", bt_switch):
        for c in re.findall(r"\.(\w+)", m.group(1)):
            coll_type[c] = m.group(2)

    # 컬렉션별 멤버 "순서 보존" 목록 — kind_coll(집합 매핑)과 별도로 배정 인덱스에 필요.
    coll_members = {}
    for m in re.finditer(r"case \.(\w+):\s*return\s*\[(.*?)\]", pc, re.S):
        coll_members[m.group(1)] = re.findall(r"\.([A-Za-z0-9_]+)", m.group(2))

    kind_generic, kind_ts = {}, {}
    for ci, coll in enumerate(coll_order):
        pool = type_pools.get(coll_type.get(coll, ""), None)
        if pool is None:
            print(f"생성 실패 — 컬렉션 {coll}의 배틀타입/타입풀 미해결", file=sys.stderr)
            sys.exit(1)
        for mi, k in enumerate(coll_members.get(coll, [])):
            g = generic_pool[(ci * stride + mi) % len(generic_pool)]
            ts = pool[mi % len(pool)]
            kind_generic[k] = [g[0], g[1]]
            kind_ts[k] = [ts[0], ts[1]]

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
    EPIC_PLUS = {"epic", "legendary", "mythic"}
    for k in kind_unique:
        if k not in kset:
            errs.append(f"unique 여분(allCases 없음): {k}")
        elif kind_rarity.get(k) not in EPIC_PLUS:
            errs.append(f"unique는 Epic+ 전용인데 {k}={kind_rarity.get(k)}")
    for k in kind_rarity:   # 역방향 — 모든 Epic+가 고유기를 갖는지(누락 방지, Swift 테스트와 대칭)
        if kind_rarity[k] in EPIC_PLUS and k not in kind_unique:
            errs.append(f"unique 누락(Epic+인데 고유기 없음): {k}")
    # 베이스 배정 검증 — 전 kind 커버 + 기존 id가 각 풀 idx0에 잔류(구 로그·골든 호환 계약).
    for k in kinds:
        if k not in kind_generic:
            errs.append(f"generic 배정 누락: {k}")
        if k not in kind_ts:
            errs.append(f"typeShared 배정 누락: {k}")
    if not generic_pool or generic_pool[0][0] != "hotfix":
        errs.append("genericPool idx0이 hotfix가 아님 (기존 id 잔류 계약 위반)")
    LEGACY_TS = {"beast": "mem_leak", "warrior": "force_push", "chaos": "friday_deploy",
                 "arcane": "context_overflow", "machine": "regression_sweep", "mascot": "onboarding"}
    for t, legacy in LEGACY_TS.items():
        pool = type_pools.get(t, [])
        if not pool or pool[0][0] != legacy:
            errs.append(f"typeShared 풀 {t} idx0이 {legacy}가 아님 (기존 id 잔류 계약 위반)")
    base_ids = [e[0] for e in generic_pool] + [e[0] for p in type_pools.values() for e in p]
    if len(base_ids) != len(set(base_ids)):
        errs.append("베이스 풀 id 중복")
    if errs:
        print("생성 실패 — 불일치:", *errs, sep="\n  ", file=sys.stderr)
        sys.exit(1)

    def ts_map(d):
        return "{\n" + "".join(f'  {k}: "{v}",\n' for k, v in sorted(d.items())) + "}"

    def ts_pair_map(d):
        return "{\n" + "".join(f'  {k}: ["{v[0]}", "{v[1]}"],\n' for k, v in sorted(d.items())) + "}"

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(
            "// AUTO-GENERATED — Swift 소스(Gacha.pool · PetCollection.members · PetSkills.uniqueTable/풀)에서 파싱. 직접 편집 금지.\n"
            f"// 재생성: scripts/gen_pet_meta.py (펫 추가/등급변경/고유기·베이스 스킬 변경 시). {len(kinds)} kinds, {len(kind_unique)} unique.\n"
            "// 서버 authoritative 스탯/스킬 계산에 필요(클라는 하드코딩하지만 서버엔 없어서 포팅).\n\n"
            f"export const RARITY: Record<string,string> = {ts_map(kind_rarity)};\n\n"
            f"export const COLLECTION: Record<string,string> = {ts_map(kind_coll)};\n\n"
            f"// Epic+ per-kind 고유기(id, name). 타입은 서버가 battleTypeOf로 파생, power는 상수(pvp_policy).\n"
            f"export const UNIQUE_SKILL: Record<string,[string,string]> = {ts_pair_map(kind_unique)};\n\n"
            f"// 베이스 스킬 per-kind 배정(id, name) — Swift 배정 공식의 resolved 산출물(카탈로그 다양화).\n"
            f"// 타입은 battleTypeOf 파생·power/rider는 상수(pvp_policy). 드리프트는 PARITYBASE 골든이 잠금.\n"
            f"export const GENERIC_SKILL: Record<string,[string,string]> = {ts_pair_map(kind_generic)};\n\n"
            f"export const TYPE_SKILL: Record<string,[string,string]> = {ts_pair_map(kind_ts)};\n"
        )
    print(f"생성 완료: {OUT} ({len(kinds)} kinds, {len(kind_unique)} unique, base {len(kind_generic)})")


if __name__ == "__main__":
    main()
