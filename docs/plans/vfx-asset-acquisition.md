# 도트 VFX 에셋 확보 가이드

> 가챠 리빌 개선 + 펫 강화 연출용 확정 팩 5종의 **다운로드 · 배치 · 라이선스** 절차.
> 조사·선정: `docs/research/pixel-vfx-assets.md` · 연출 설계: `docs/plans/pet-battle.md` §9.
> 작성: 2026-07.

## 0. 왜 별도 가이드인가

- 이 팩들은 **GitHub 미러가 없다** — 펫 팩에서 쓰던 `gh api search/code` base64 우회가 안 통한다.
- 사내망은 itch.io / opengameart.org가 **TLS 차단** 전례가 있다([[pet-asset-sourcing]]). → **개인망에서 받거나** 아래 itch 비공식 흐름을 쓴다.
- 확보는 **사람이 하는 단계**(브라우저 다운로드가 가장 안전). 자동화는 fallback.

## 1. 확정 팩 (5종)

| # | 팩 | 제작자 | 라이선스 | 1차 URL | 받는 법 |
|---|---|---|---|---|---|
| 1 | Hatching Egg Sprites | Nightspore | 커스텀 무료 (상업 OK, NFT/AI 도용 금지) | https://nightspore.itch.io/hatching-egg-sprites | itch |
| 2 | Mini FX, Items & UI | GrafxKid | **CC0** | https://grafxkid.itch.io/mini-fx-items-ui | itch |
| 3 | Free Pixel Effects Pack | CodeManu | **CC0** (OGA 미러 기준) | https://codemanu.itch.io/pixelart-effect-pack · 미러 https://opengameart.org/content/free-pixel-effects-pack | itch **또는 OGA** |
| 4 | Explosion + Ring Explosion | BenHickling | **CC0** | https://opengameart.org/content/explosion-7 · https://opengameart.org/content/ring-explosion | **OGA 직다운(권장)** |
| 5 | Pixel Magic Effects | Foozle | **CC0** | https://foozlecc.itch.io/pixel-magic-sprite-effects | itch |
| 5-alt | Pixel Art Spells (16px) | DevWizard | **CC0** | https://opengameart.org/content/pixel-art-spells | OGA 직다운 |

> 5-alt(Pixel Art Spells)는 16px라 DungeonTileset II 그리드와 완전 호환 + OGA 직다운이라 사내망 리스크가 낮다. Foozle(32px)보다 확보가 쉬우니 **차지/오라는 5-alt 우선 시도** 권장.

## 2. 받는 법

### 2-A. OGA 직다운 (BenHickling·CodeManu 미러·Pixel Art Spells) — 가장 쉬움

OGA는 페이지에 직접 파일 링크가 있다. 개인망(또는 사내망이 열려 있으면)에서:

```bash
# 예: BenHickling — 페이지에서 실제 파일 URL을 확인 후
curl -L -o explosion.png   "https://opengameart.org/sites/default/files/explosion1_0.png"
curl -L -o ring.png        "https://opengameart.org/sites/default/files/explosion2.png"
# ※ 실제 파일 경로는 각 OGA 페이지의 "Art Files" 섹션 링크로 확정할 것(파일명이 버전마다 다름)
```

### 2-B. itch 브라우저 다운로드 (Nightspore·GrafxKid·Foozle) — 권장

itch "name your own price"/무료 팩은 브라우저가 가장 확실:
1. 개인망 브라우저로 팩 URL 열기 → **Download** (무료는 "No thanks, just take me to the downloads" 또는 $0 입력).
2. zip 저장 → 압축 해제.

### 2-C. itch 비공식 흐름 (헤드리스 fallback, [[pet-asset-sourcing]] 검증)

브라우저를 못 쓸 때만. 세션 쿠키 필요할 수 있음:
```
POST https://<user>.itch.io/<slug>/download_url   (csrf 포함) → JSON {url}
  → 그 페이지에서 data-upload_id + csrf2 추출
  → POST /<slug>/file/<upload_id> (csrf2) → 서명된 S3 URL
  → 서명 URL 다운로드
```
pet-expansion-200에서 이 흐름으로 받은 전례 있음. 실패 시 2-B로.

## 3. 배치 (SwiftPM Resources)

**불변식**: SwiftPM 리소스는 flatten되므로 `Resources/` 하위 **모든 PNG/LICENSE basename이 유니크**해야 한다(CLAUDE.md). 팩별 디렉터리 + prefix로 관리:

```
Resources/
  vfx-egg/          # Nightspore — vfx_egg_hatch_00.png … + LICENSE_Nightspore.txt
  vfx-grafxkid-fx/  # GrafxKid Mini FX — vfx_gk_sparkle_*.png, vfx_gk_poof_*.png
  vfx-codemanu/     # CodeManu — vfx_cm_explosion_*.png, vfx_cm_star_*.png (+ LICENSE_CodeManu.txt, 안전차원)
  vfx-benhickling/  # Explosion + Ring — vfx_bh_explosion_*.png, vfx_bh_ring_*.png
  vfx-spells/       # Pixel Art Spells (5-alt) — vfx_sp_orb_*.png, vfx_sp_shield_*.png
```

### 프레임 분해 (스트립 → 개별 프레임)

일부 팩은 가로 스트립/시트로 온다. 셀 크기를 실측 후 크롭:
```bash
# 예: 100×100, 가로 N프레임 스트립을 개별 파일로
magick strip.png -crop 100x100 +repage vfx_cm_explosion_%02d.png
```
- 기존 펫 팩의 asset-import 스크립트(빌드 밖, CLAUDE.md 언급)와 동일 방식으로 스트립을 처리.
- Nightspore는 rock/bounce/crack/hatch 단계별 + 4색 → 색 하나(예: cream)만 우선 채택해 용량 절감 가능.

## 4. 라이선스 처리

| 팩 | attribution | 파일 |
|---|---|---|
| GrafxKid / CodeManu(OGA 미러) / BenHickling / Pixel Art Spells / Foozle | 불요(CC0) | (선택) 감사 표시 |
| **Nightspore** | 불요이나 **커스텀 조항 원문 보존 필수** | `Resources/vfx-egg/LICENSE_Nightspore.txt`에 원문 인용: *"For free or commercial games. Not for use in NFTs, Crypto, AI or other machine-generated grift."* |
| CodeManu | itch 본문 CC0 vs 메타 CC-BY 불일치 → **안전차원 크레딧 문구 포함 무방** | `LICENSE_CodeManu.txt`(선택) |

- 설정 창 "에셋 크레딧"(SettingsView) 섹션에 신규 팩을 추가(기존 CC-BY 팩과 동일 패턴).
- 라이선스 카테고리가 CC0/CC-BY 이원 → **+Nightspore 커스텀 1종** 늘어남을 CLAUDE.md 에셋 표에 반영.

## 5. 체크리스트

- [ ] 개인망에서 5팩(1~5, 5는 5-alt 우선) 다운로드
- [ ] 각 팩 셀 크기 실측 → 스트립이면 프레임 분해
- [ ] `Resources/vfx-*/`에 유니크 basename + prefix로 배치
- [ ] Nightspore `LICENSE_Nightspore.txt` 원문 보존
- [ ] SettingsView 에셋 크레딧 + CLAUDE.md 에셋 표 갱신
- [ ] 실물 육안 확인 — 채도·외곽선이 기존 펫 팩과 조화되는지 (조사는 텍스트 기반, 톤은 미검증)
- [ ] `swift build`로 리소스 basename 충돌 없는지 확인

## 6. 미해결 / 후속

- 톤 육안 검증 미완(다운로드 후). 안 맞으면 대체 후보는 `docs/research/pixel-vfx-assets.md` "참고 자료" 섹션.
- 전용 **shard(산산조각)** 프레임은 CC0 부재 → 파괴 연출은 폭발+연기로 대체(§9-2). 정말 필요하면 unTied Games Gigapack(attribution 필수) 재검토.
- PixelDuck 충격파 16종·Frostwindz 연기 팩은 라이선스 미확인(후속 조사 가치).
