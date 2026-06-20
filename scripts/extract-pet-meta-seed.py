#!/usr/bin/env python3
"""현재 Swift 코드에서 펫 메타데이터(이름/대사/설명)를 추출해 pet_metadata UPSERT SQL을
stdout으로 출력한다. 배포 시 1회 실행해 서버 테이블을 현재 코드값으로 seed한다.

    python3 scripts/extract-pet-meta-seed.py > /tmp/pet_seed.sql

- 소스: Sources/ClaudeUsage/{PetSprite,PetDescriptions,Quotes}.swift
- 출력 SQL은 ON CONFLICT (kind) DO UPDATE — 반복 실행 안전(현재 코드값으로 덮어씀).
- 코드 포맷(특히 PetDefinition/perPet 리터럴)이 크게 바뀌면 아래 정규식도 함께 갱신할 것.
- 추출 종 수를 stderr로 보고하니, 기대값(현 79종)과 맞는지 확인하고 적용한다.
"""
import re
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Sources" / "ClaudeUsage"


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


def unescape_swift(s: str) -> str:
    return s.replace('\\"', '"').replace("\\\\", "\\")


def sql_quote(s: str) -> str:
    return s.replace("'", "''")


# 1) displayName — PetSprite.swift 의 `def` switch:
#    case .fox:\n  return PetDefinition(prefix: "Fox", displayName: "여우", ...
sprite = read("PetSprite.swift")
names: dict[str, str] = {}
for m in re.finditer(
    r'case \.(\w+):\s*\n\s*return PetDefinition\(prefix:\s*"[^"]*",\s*displayName:\s*"((?:[^"\\]|\\.)*)"',
    sprite,
):
    names[m.group(1)] = unescape_swift(m.group(2))

# 2) description — PetDescriptions.swift 의 perPet: `.kind: "..."`
desc_src = read("PetDescriptions.swift")
descs: dict[str, str] = {}
for m in re.finditer(r'\.(\w+):\s*"((?:[^"\\]|\\.)*)"', desc_src):
    descs[m.group(1)] = unescape_swift(m.group(2))

# 3) quotes — Quotes.swift 의 perPet: `.kind: ["a", "b", ...]`
#    wellness/reactions 는 `.kind:` 형태가 아니라 매칭되지 않음.
quotes_src = read("Quotes.swift")
quotes: dict[str, list[str]] = {}
for m in re.finditer(r"\.(\w+):\s*\[((?:[^\[\]]|\n)*?)\]", quotes_src):
    arr = [unescape_swift(q) for q in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2))]
    if arr:
        quotes[m.group(1)] = arr

# displayName(PetSprite)을 종 목록의 기준으로 사용 — 모든 PetKind가 def를 가지므로.
kinds = sorted(names.keys())
missing_desc = [k for k in kinds if k not in descs]
missing_quotes = [k for k in kinds if k not in quotes]
if missing_desc:
    print(f"WARN: description 누락 {missing_desc}", file=sys.stderr)
if missing_quotes:
    print(f"WARN: quotes 누락 {missing_quotes}", file=sys.stderr)

rows = []
for k in kinds:
    dn = names[k]
    de = descs.get(k, "")
    qs = quotes.get(k, [])
    qjson = json.dumps(qs, ensure_ascii=False)
    rows.append(
        f"  ('{sql_quote(k)}', '{sql_quote(dn)}', '{sql_quote(de)}', '{sql_quote(qjson)}'::jsonb)"
    )

if "--json" in sys.argv:
    # service_role PostgREST upsert 용 JSON 배열(컬럼명 = snake_case).
    out = [
        {"kind": k, "display_name": names[k],
         "description": descs.get(k, ""), "quotes": quotes.get(k, [])}
        for k in kinds
    ]
    print(json.dumps(out, ensure_ascii=False))
    print(f"추출 완료(JSON): {len(kinds)}종", file=sys.stderr)
    sys.exit(0)

print("-- 자동 생성: scripts/extract-pet-meta-seed.py (현재 코드값 snapshot)")
print("INSERT INTO pet_metadata (kind, display_name, description, quotes) VALUES")
print(",\n".join(rows))
print("ON CONFLICT (kind) DO UPDATE SET")
print("  display_name = EXCLUDED.display_name,")
print("  description  = EXCLUDED.description,")
print("  quotes       = EXCLUDED.quotes,")
print("  updated_at   = now();")

print(f"추출 완료: {len(kinds)}종 (desc {len(descs)}, quotes {len(quotes)})", file=sys.stderr)
