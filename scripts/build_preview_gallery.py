#!/usr/bin/env python3
"""프리뷰 매니페스트(JSONL) → 검수용 HTML 갤러리.

`scripts/render-previews.sh`가 호출한다. 직접 쓸 일은 `dist/previews`를 이미 구워둔 뒤
갤러리만 다시 만들 때 정도다:

    python3 scripts/build_preview_gallery.py dist/previews

갤러리가 갖춰야 하는 것:
  - 한 화면에 많이 보이고, 배경을 바꿔볼 수 있고(투명 스프라이트는 배경색에 따라 결함이
    보였다 안 보였다 한다), 클릭하면 원본 크기로 볼 수 있을 것.
  - **현재 보는 것만 로딩할 것.** 174장(GIF 34개 포함, 3.5MB)을 한 페이지에 전부 넣으면
    `loading="lazy"`가 있어도 느리다 — GIF는 뷰포트에 들어오는 즉시 전량 디코딩되고 계속
    재생되므로, 화면 밖에 있어도 메모리와 CPU를 먹는다. 그래서 탭(기능) → 섹션 → 페이지로
    쪼개고, **현재 페이지의 카드만 DOM에 만든다**. 페이지를 넘기면 이전 카드는 DOM에서
    사라지므로 GIF 디코딩도 함께 해제된다.

메타데이터는 HTML에 인라인으로 심는다. `file://`에서 열리는 페이지라 fetch가 막히기 때문에
외부 JSON을 두면 로드되지 않는다(174개 메타는 수십 KB라 인라인해도 부담이 없다).
"""
import json
import os
import sys
from collections import OrderedDict

# 섹션 → 상단 탭(기능) 묶음. 섹션 이름 컨벤션에서 파생한다:
#   "애니 · X"      → 애니메이션 탭
#   "화면 · 라이트/다크" → 화면 탭 (모드별 섹션 칩)
#   "트레이너 카드*" → 트레이너 카드 탭
#   그 외          → 섹션 이름이 곧 탭
# 탭을 명시 필드로 만들지 않은 것은 렌더러 5개 파일을 고치지 않기 위해서다. 컨벤션이 깨지면
# 여기 규칙을 먼저 볼 것.
def group_of(section: str) -> str:
    if section.startswith("애니"):
        return "애니메이션"
    if section.startswith("화면"):
        return "화면"
    if section.startswith("월드맵"):
        return "월드맵"
    if section.startswith("트레이너 카드"):
        return "트레이너 카드"
    if section.startswith("펫"):
        return "펫 스프라이트"
    return section


# 탭 정렬 순서. 여기 없는 이름은 뒤에 이름순으로 붙는다.
TAB_ORDER = ["펫 스프라이트", "애니메이션", "트레이너 카드", "화면", "월드맵", "길드", "배틀"]

HTML = r"""<!doctype html>
<meta charset="utf-8">
<title>AIUsage 프리뷰 검수</title>
<style>
  :root { --bg:#15161a; --fg:#e9e9ee; --dim:#9a9aa6; --line:#2c2d35; --card:#1d1e24; --col:320px; }
  * { box-sizing:border-box }
  body { margin:0; font:14px/1.5 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
         background:var(--bg); color:var(--fg) }
  header { position:sticky; top:0; z-index:10; background:rgba(21,22,26,.97);
           border-bottom:1px solid var(--line); backdrop-filter:saturate(140%) blur(8px) }
  .bar { display:flex; gap:14px; align-items:center; flex-wrap:wrap; padding:10px 20px }
  .bar + .bar { border-top:1px solid var(--line) }
  h1 { font-size:15px; margin:0; font-weight:600; letter-spacing:.2px }
  .meta { color:var(--dim); font-size:12px }
  .spacer { margin-left:auto }
  button { font:inherit; color:var(--fg); background:var(--card); border:1px solid var(--line);
           border-radius:6px; padding:4px 10px; cursor:pointer }
  button:hover { border-color:#4a4b57 }
  button[aria-pressed="true"], button.on { border-color:#6b6cff; color:#c9caff; background:#22233a }
  button:disabled { opacity:.35; cursor:default }
  .tabs { display:flex; gap:6px; flex-wrap:wrap }
  .tabs button { border-radius:99px; font-size:12.5px }
  .tabs .n { color:var(--dim); font-size:11px; margin-left:5px }
  .chips { display:flex; gap:6px; flex-wrap:wrap }
  .chips button { border-radius:99px; font-size:11.5px; padding:2px 9px; color:var(--dim) }
  .ctl { display:flex; gap:6px; align-items:center; font-size:12px; color:var(--dim) }
  .ctl button { font-size:11.5px; padding:3px 9px }
  input[type=search] { font:inherit; font-size:12px; color:var(--fg); background:var(--card);
                       border:1px solid var(--line); border-radius:6px; padding:4px 9px; width:160px }
  main { padding:16px 20px 60px }
  .grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(var(--col), 1fr)); gap:14px }
  figure { margin:0; background:var(--card); border:1px solid var(--line); border-radius:10px;
           overflow:hidden; display:flex; flex-direction:column }
  /* overflow는 hidden이어야 한다. auto로 두면 카드 위에서 굴린 휠을 카드 내부 스크롤이
     먹어버려 페이지가 내려가지 않고, 하단 페이저에 도달할 수 없다. 원본 크기로 볼 방법은
     클릭 확대가 이미 제공한다. */
  .imgwrap { padding:10px; display:flex; justify-content:center; align-items:center;
             max-height:56vh; overflow:hidden }
  .imgwrap img { max-width:100%; max-height:calc(56vh - 20px); width:auto; height:auto;
                 object-fit:contain; image-rendering:pixelated; cursor:zoom-in }
  figcaption { padding:8px 11px 11px; border-top:1px solid var(--line) }
  .title { font-size:12.5px; font-weight:600 }
  .sect { font-size:10.5px; color:#7c7d8c; margin-top:2px }
  .badge { display:inline-block; font-size:10px; font-weight:600; letter-spacing:.04em;
           color:#c9caff; background:#2b2c4a; border:1px solid #45467a;
           border-radius:4px; padding:0 5px; margin-left:6px; vertical-align:1px }
  .note { font-size:11.5px; color:var(--dim); margin-top:3px }
  .dim { font-size:11px; color:#6f7080; margin-top:3px; font-variant-numeric:tabular-nums }
  .pager { display:flex; gap:8px; align-items:center; justify-content:center;
           padding:20px 0 0; color:var(--dim); font-size:12px }
  .empty { color:var(--dim); padding:40px 0; text-align:center }
  body[data-bg="light"] .imgwrap { background:#f4f4f6 }
  body[data-bg="dark"] .imgwrap { background:#0b0b0e }
  body[data-bg="checker"] .imgwrap {
    background-image:linear-gradient(45deg,#33343d 25%,transparent 25%,transparent 75%,#33343d 75%),
                     linear-gradient(45deg,#33343d 25%,transparent 25%,transparent 75%,#33343d 75%);
    background-size:16px 16px; background-position:0 0, 8px 8px; background-color:#26272e }
  dialog { border:none; background:transparent; max-width:96vw; max-height:96vh; padding:0 }
  dialog::backdrop { background:rgba(0,0,0,.82) }
  dialog img { max-width:96vw; max-height:96vh; image-rendering:pixelated; cursor:zoom-out }
</style>
<body data-bg="checker">
<header>
  <div class="bar">
    <h1>AIUsage 프리뷰 검수</h1>
    <span class="meta">__COUNT__장 · __GENERATED__</span>
    <span class="spacer"></span>
    <span class="ctl">배경
      <button data-bg="checker" aria-pressed="true">체커</button>
      <button data-bg="dark">어둡게</button>
      <button data-bg="light">밝게</button>
    </span>
    <span class="ctl">크기
      <button data-col="240">작게</button>
      <button data-col="320" aria-pressed="true">보통</button>
      <button data-col="520">크게</button>
    </span>
    <span class="ctl">쪽당
      <button data-per="12" aria-pressed="true">12</button>
      <button data-per="24">24</button>
      <button data-per="48">48</button>
    </span>
    <input type="search" id="q" placeholder="이름 검색">
  </div>
  <div class="bar"><div class="tabs" id="tabs"></div></div>
  <div class="bar"><div class="chips" id="chips"></div></div>
</header>
<main>
  <div class="grid" id="grid"></div>
  <div class="pager" id="pager"></div>
</main>
<dialog id="zoom"><img></dialog>
<script>
const DATA = __DATA__;
const TABS = __TABS__;

// 기본 쪽당 12 — 카드가 크고, 애니 탭은 한 장이 MB 단위라 24면 첫 페이지가 무겁다.
const state = { tab: TABS[0] || "", section: "*", page: 0, per: 12, q: "" };
const $ = (id) => document.getElementById(id);

function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;" }[c])); }

function inTab(d) { return d.group === state.tab; }
function filtered() {
  const q = state.q.trim().toLowerCase();
  return DATA.filter(d => inTab(d)
    && (state.section === "*" || d.section === state.section)
    && (!q || d.title.toLowerCase().includes(q) || d.section.toLowerCase().includes(q)));
}

function renderTabs() {
  $("tabs").innerHTML = TABS.map(t => {
    const n = DATA.filter(d => d.group === t).length;
    return `<button data-tab="${esc(t)}" class="${t === state.tab ? "on" : ""}">${esc(t)}<span class="n">${n}</span></button>`;
  }).join("");
}

function renderChips() {
  // 탭 안의 섹션들. 하나뿐이면 칩 줄 자체를 숨긴다.
  const sections = [...new Set(DATA.filter(inTab).map(d => d.section))];
  const bar = $("chips").parentElement;
  if (sections.length <= 1) { bar.style.display = "none"; $("chips").innerHTML = ""; return; }
  bar.style.display = "";
  const all = DATA.filter(inTab).length;
  $("chips").innerHTML = [`<button data-section="*" class="${state.section === "*" ? "on" : ""}">전체 <span class="n">${all}</span></button>`]
    .concat(sections.map(s => {
      const n = DATA.filter(d => inTab(d) && d.section === s).length;
      return `<button data-section="${esc(s)}" class="${state.section === s ? "on" : ""}">${esc(s)} <span class="n">${n}</span></button>`;
    })).join("");
}

function renderGrid() {
  const items = filtered();
  const pages = Math.max(1, Math.ceil(items.length / state.per));
  if (state.page >= pages) state.page = pages - 1;
  const slice = items.slice(state.page * state.per, (state.page + 1) * state.per);

  // innerHTML 통째 교체 = 이전 페이지 카드가 DOM에서 사라진다. GIF 디코딩/재생도 함께 멈춘다.
  $("grid").innerHTML = slice.map(d => {
    const badge = d.animated ? `<span class="badge">▶ ${d.frames}f</span>` : "";
    const dim = `${d.width}×${d.height}px` + (d.animated ? ` · ${d.frames}프레임` : "");
    const note = d.note ? `<div class="note">${esc(d.note)}</div>` : "";
    const sect = state.section === "*" ? `<div class="sect">${esc(d.section)}</div>` : "";
    return `<figure><div class="imgwrap"><img src="${esc(d.path)}" alt="${esc(d.title)}"></div>`
         + `<figcaption><div class="title">${esc(d.title)}${badge}</div>${sect}${note}`
         + `<div class="dim">${dim}</div></figcaption></figure>`;
  }).join("") || `<div class="empty">해당하는 프리뷰가 없다</div>`;

  $("pager").innerHTML = items.length
    ? `<button id="prev" ${state.page === 0 ? "disabled" : ""}>← 이전</button>`
      + `<span>${state.page + 1} / ${pages} · ${items.length}장</span>`
      + `<button id="next" ${state.page >= pages - 1 ? "disabled" : ""}>다음 →</button>`
    : "";
  if ($("prev")) $("prev").onclick = () => { state.page--; renderGrid(); scrollTo(0, 0); };
  if ($("next")) $("next").onclick = () => { state.page++; renderGrid(); scrollTo(0, 0); };

  for (const img of document.querySelectorAll(".imgwrap img")) {
    img.onclick = () => { const dlg = $("zoom"); dlg.querySelector("img").src = img.src; dlg.showModal(); };
  }
  location.hash = encodeURIComponent(state.tab) + "/" + (state.page + 1);
}

function renderAll() { renderTabs(); renderChips(); renderGrid(); }

$("tabs").onclick = (e) => {
  const b = e.target.closest("[data-tab]"); if (!b) return;
  state.tab = b.dataset.tab; state.section = "*"; state.page = 0; renderAll(); scrollTo(0, 0);
};
$("chips").onclick = (e) => {
  const b = e.target.closest("[data-section]"); if (!b) return;
  state.section = b.dataset.section; state.page = 0; renderChips(); renderGrid();
};
$("q").oninput = (e) => { state.q = e.target.value; state.page = 0; renderGrid(); };
$("zoom").onclick = () => $("zoom").close();

for (const b of document.querySelectorAll("[data-bg]")) {
  if (b.tagName !== "BUTTON") continue;
  b.onclick = () => {
    document.body.dataset.bg = b.dataset.bg;
    document.querySelectorAll("[data-bg]").forEach(x => { if (x.tagName === "BUTTON") x.setAttribute("aria-pressed", x === b); });
  };
}
for (const b of document.querySelectorAll("[data-col]")) {
  b.onclick = () => {
    document.documentElement.style.setProperty("--col", b.dataset.col + "px");
    document.querySelectorAll("[data-col]").forEach(x => x.setAttribute("aria-pressed", x === b));
  };
}
for (const b of document.querySelectorAll("[data-per]")) {
  b.onclick = () => {
    state.per = +b.dataset.per; state.page = 0;
    document.querySelectorAll("[data-per]").forEach(x => x.setAttribute("aria-pressed", x === b));
    renderGrid();
  };
}
// 새로고침·뒤로가기에서 보던 탭/페이지로 복귀.
const h = decodeURIComponent(location.hash.slice(1)).split("/");
if (h[0] && TABS.includes(h[0])) state.tab = h[0];
if (h[1] && +h[1] > 0) state.page = +h[1] - 1;
renderAll();
</script>
"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "dist/previews"
    rows = []
    with open(os.path.join(out, "manifest.jsonl"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))

    for r in rows:
        r["group"] = group_of(r["section"])

    # 테스트 실행 순서가 보장되지 않으므로 여기서 정렬한다 — 안 그러면 다시 구울 때마다
    # 갤러리 순서가 흔들려 이전 결과와 비교할 수 없다.
    rows.sort(key=lambda r: (r["group"], r["section"], r["title"]))

    groups = list(OrderedDict.fromkeys(r["group"] for r in rows))
    tabs = [g for g in TAB_ORDER if g in groups] + sorted(g for g in groups if g not in TAB_ORDER)

    generated = ""
    try:
        import datetime
        generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    except Exception:
        pass

    html = (HTML
            .replace("__DATA__", json.dumps(rows, ensure_ascii=False))
            .replace("__TABS__", json.dumps(tabs, ensure_ascii=False))
            .replace("__COUNT__", str(len(rows)))
            .replace("__GENERATED__", generated))
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(html)


if __name__ == "__main__":
    main()
