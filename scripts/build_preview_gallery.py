#!/usr/bin/env python3
"""프리뷰 매니페스트(JSONL) → 검수용 HTML 갤러리.

`scripts/render-previews.sh`가 호출한다. 직접 쓸 일은 `dist/previews`를 이미 구워둔 뒤
갤러리만 다시 만들 때 정도다:

    python3 scripts/build_preview_gallery.py dist/previews

갤러리가 갖춰야 하는 것은 세 가지뿐이다 — 한 화면에 많이 보이고, 배경을 바꿔볼 수 있고
(투명 스프라이트는 배경색에 따라 결함이 보였다 안 보였다 한다), 클릭하면 원본 크기로 볼 수 있을 것.
"""
import json
import os
import sys
from collections import OrderedDict

HTML = """<!doctype html>
<meta charset="utf-8">
<title>AIUsage 프리뷰 검수</title>
<style>
  :root {{ --bg:#15161a; --fg:#e9e9ee; --dim:#9a9aa6; --line:#2c2d35; --card:#1d1e24; }}
  * {{ box-sizing:border-box }}
  body {{ margin:0; font:14px/1.5 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
         background:var(--bg); color:var(--fg) }}
  header {{ position:sticky; top:0; z-index:10; background:rgba(21,22,26,.96);
            border-bottom:1px solid var(--line); padding:12px 20px;
            display:flex; gap:16px; align-items:center; flex-wrap:wrap;
            backdrop-filter:saturate(140%) blur(8px) }}
  h1 {{ font-size:15px; margin:0; font-weight:600; letter-spacing:.2px }}
  .meta {{ color:var(--dim); font-size:12px }}
  nav {{ display:flex; gap:6px; flex-wrap:wrap; margin-left:auto }}
  nav a {{ color:var(--dim); text-decoration:none; font-size:12px; padding:3px 9px;
           border:1px solid var(--line); border-radius:99px }}
  nav a:hover {{ color:var(--fg); border-color:#4a4b57 }}
  .controls {{ display:flex; gap:8px; align-items:center; font-size:12px; color:var(--dim) }}
  .controls button {{ font:inherit; color:var(--fg); background:var(--card);
                      border:1px solid var(--line); border-radius:6px; padding:4px 10px; cursor:pointer }}
  .controls button[aria-pressed="true"] {{ border-color:#6b6cff; color:#c9caff }}
  section {{ padding:20px }}
  h2 {{ font-size:13px; text-transform:uppercase; letter-spacing:.08em; color:var(--dim);
        margin:0 0 12px; font-weight:600 }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(var(--col,320px), 1fr)); gap:14px }}
  figure {{ margin:0; background:var(--card); border:1px solid var(--line); border-radius:10px;
            overflow:hidden; display:flex; flex-direction:column }}
  .imgwrap {{ padding:10px; display:flex; justify-content:center; align-items:flex-start;
              max-height:70vh; overflow:auto }}
  .imgwrap img {{ max-width:100%; height:auto; image-rendering:pixelated; cursor:zoom-in }}
  figcaption {{ padding:8px 11px 11px; border-top:1px solid var(--line) }}
  .title {{ font-size:12.5px; font-weight:600 }}
  .badge {{ display:inline-block; font-size:10px; font-weight:600; letter-spacing:.04em;
            color:#c9caff; background:#2b2c4a; border:1px solid #45467a;
            border-radius:4px; padding:0 5px; margin-left:6px; vertical-align:1px }}
  .note {{ font-size:11.5px; color:var(--dim); margin-top:3px }}
  .dim {{ font-size:11px; color:#6f7080; margin-top:3px; font-variant-numeric:tabular-nums }}
  body[data-bg="light"] .imgwrap {{ background:#f4f4f6 }}
  body[data-bg="dark"] .imgwrap {{ background:#0b0b0e }}
  body[data-bg="checker"] .imgwrap {{
    background-image:linear-gradient(45deg,#33343d 25%,transparent 25%,transparent 75%,#33343d 75%),
                     linear-gradient(45deg,#33343d 25%,transparent 25%,transparent 75%,#33343d 75%);
    background-size:16px 16px; background-position:0 0, 8px 8px; background-color:#26272e }}
  dialog {{ border:none; background:transparent; max-width:96vw; max-height:96vh; padding:0 }}
  dialog::backdrop {{ background:rgba(0,0,0,.82) }}
  dialog img {{ max-width:96vw; max-height:96vh; image-rendering:pixelated; cursor:zoom-out }}
</style>
<body data-bg="checker">
<header>
  <h1>AIUsage 프리뷰 검수</h1>
  <span class="meta">{count}장 · {generated}</span>
  <span class="controls">
    배경
    <button data-bg="checker" aria-pressed="true">체커</button>
    <button data-bg="dark">어둡게</button>
    <button data-bg="light">밝게</button>
    크기
    <button data-col="240">작게</button>
    <button data-col="320" aria-pressed="true">보통</button>
    <button data-col="520">크게</button>
  </span>
  <nav>{nav}</nav>
</header>
{sections}
<dialog id="zoom"><img></dialog>
<script>
  const body = document.body;
  for (const b of document.querySelectorAll('[data-bg]')) {{
    if (b.tagName !== 'BUTTON') continue;
    b.onclick = () => {{
      body.dataset.bg = b.dataset.bg;
      document.querySelectorAll('[data-bg]').forEach(x => {{
        if (x.tagName === 'BUTTON') x.setAttribute('aria-pressed', x === b);
      }});
    }};
  }}
  for (const b of document.querySelectorAll('[data-col]')) {{
    b.onclick = () => {{
      document.documentElement.style.setProperty('--col', b.dataset.col + 'px');
      document.querySelectorAll('[data-col]').forEach(x => x.setAttribute('aria-pressed', x === b));
    }};
  }}
  const dlg = document.getElementById('zoom');
  document.querySelectorAll('.imgwrap img').forEach(img => {{
    img.onclick = () => {{ dlg.querySelector('img').src = img.src; dlg.showModal(); }};
  }});
  dlg.onclick = () => dlg.close();
</script>
"""


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "dist/previews"
    manifest = os.path.join(out, "manifest.jsonl")
    rows = []
    with open(manifest, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))

    # 섹션 순서는 첫 등장 순이 아니라 이름 순 — 테스트 실행 순서가 보장되지 않아서,
    # 그대로 두면 다시 구울 때마다 갤러리 순서가 흔들려 비교가 어렵다.
    sections = OrderedDict()
    for r in sorted(rows, key=lambda r: (r["section"], r["title"])):
        sections.setdefault(r["section"], []).append(r)

    nav = "".join(f'<a href="#{esc(s)}">{esc(s)}</a>' for s in sections)
    body = []
    for name, items in sections.items():
        cards = []
        for it in items:
            note = f'<div class="note">{esc(it["note"])}</div>' if it.get("note") else ""
            # GIF는 재생 중임을 명시한다 — 정지 컷과 섞여 있으면 "왜 안 움직이지"를 헷갈린다.
            badge = f'<span class="badge">▶ {it.get("frames", 0)}f</span>' if it.get("animated") else ""
            dim = f'{it["width"]}×{it["height"]}px'
            if it.get("animated"):
                dim += f' · {it.get("frames", 0)}프레임'
            cards.append(
                f'<figure><div class="imgwrap"><img loading="lazy" src="{esc(it["path"])}" alt="{esc(it["title"])}"></div>'
                f'<figcaption><div class="title">{esc(it["title"])}{badge}</div>{note}'
                f'<div class="dim">{dim}</div></figcaption></figure>'
            )
        body.append(
            f'<section id="{esc(name)}"><h2>{esc(name)} <span class="meta">({len(items)})</span></h2>'
            f'<div class="grid">{"".join(cards)}</div></section>'
        )

    generated = ""
    try:
        import datetime
        generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    except Exception:
        pass

    html = HTML.format(count=len(rows), generated=generated,
                       nav=nav, sections="".join(body))
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(html)


if __name__ == "__main__":
    main()
