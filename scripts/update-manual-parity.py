#!/usr/bin/env python3
"""Copy Swift-exported parity vectors, retaining mutable state and semantic events."""
import json
import sys
from pathlib import Path

def slim(value):
    if isinstance(value, dict):
        return {key: slim(item) for key, item in value.items() if key not in ("text", "summary", "name")}
    if isinstance(value, list):
        return [slim(item) for item in value]
    return value

def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: update-manual-parity.py <Swift export.json>")
    vectors = json.loads(Path(sys.argv[1]).read_text())
    for vector in vectors:
        vector["steps"] = [{"command": step["command"], "expected": slim(step["expected"])} for step in vector["steps"]]
    target = Path(__file__).resolve().parents[1] / "supabase/functions/_shared/manual_battle.vectors.json"
    target.write_text(json.dumps(vectors, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(vectors)} vectors written to {target.name}")

if __name__ == "__main__":
    main()
