# 강화(업그레이드) 시 "대상 자체"에 걸리는 시각 이펙트 리서치 — 펫 강화(도박) 연출 설계용

조사일: 2026-07-16
조사 목적: `docs/research/maplestory-enhancement.md`(확률/리스크 구조), `docs/research/dnf-enhancement.md`(확률/리스크 구조),
`docs/research/pixel-vfx-assets.md`(오버레이 VFX 에셋 소싱)와 **중복되지 않는 각도** — 강화 시도의 각 단계(차지→성공/실패/파괴)에서
**대상(장비/캐릭터/펫) 스프라이트 자체가 어떻게 반응하는지**만 조사. 목적은 AIUsage 앱의 "펫 강화(도박)" 화면에서 정적인 펫 스프라이트에
반응 연출을 추가하기 위함.

---

## 요약 (3줄)

- 상용 게임들은 대상 자체의 반응을 "차지(펄스/발광 진동) → 성공(플래시+스케일 팝+지속 오라) → 실패(짧은 흔들림) → 파괴(그레이스케일+붕괴+파편)"의 4단 계단식 강도로 설계하며, 이 중 다수는 **스프라이트 변형만으로 구현 가능**(scale, shake, hueRotation, grayscale, opacity)하다는 것이 일반 게임 개발 문헌(Game Feel/Juice, hit-flash 셰이더 튜토리얼)에서 반복 확인된다.
- 로스트아크(Lost Ark)의 무기 강화는 **강화 단계별로 무기 자체에 다른 색의 오라가 상시로 걸리는(19강 핑크→20강 하늘+금→23~24강 주황/노랑→25강 흰색)** 사례로, "대상 자체 색상 변화로 등급을 표현"하는 가장 구체적인 참고 사례다(단, 커뮤니티 게시글 출처, 넥슨/스마일게이트 1차 공식 확인은 못함).
- 메이플스토리는 강화 연출을 온오프 토글 가능하게 만들고 20성/25성 임계값부터만 전체화면 연출을 추가하는데, 이는 "저단계는 담백하게, 고단계일수록 연출을 무겁게"라는 계단식 강도 설계와 일치— 우리 강화소도 낮은 강화 단계(펫 강화 초반)엔 네이티브 연출만, 고단계/고레어리티일수록 에셋 오버레이를 추가하는 방식을 고려할 만하다(권장, 추정 포함).

## 권장 결론 (트레이드오프 명시, 단정 회피)

- **(a) 네이티브 스프라이트 변형만으로 4단계 전부의 최소 버전을 구현 가능**하다 — SwiftUI가 `.scaleEffect`, `.rotationEffect`, `.hueRotation`, `.saturation`, `.grayscale`, `.opacity`, `.brightness`를 공식 View modifier로 제공하고(Apple 공식 API, WWDC24 세션에서도 `visualEffect()`로 조합 가능함을 확인), shake는 커뮤니티에 널리 퍼진 `GeometryEffect` 기반 sin 변형 패턴(objc.io, WWDC21 "Animating Tilt and Shake with GeometryEffect")으로 구현할 수 있다. 이 조합만으로도 "차지 펄스/성공 팝/실패 흔들림/파괴 그레이스케일"의 뼈대는 에셋 없이 완성된다.
- **(b) 오버레이 VFX(폭발/파편/파티클/충격파)는 임팩트를 극대화하지만 필수는 아니다** — Game Feel/Juice 문헌은 "juice는 이미 작동하는 것 위에 얹는 폴리시(polish)이지, 게임이 성립하기 위한 필수 요소가 아니다"라고 명시적으로 구분한다([valdemird.com](https://valdemird.com/blog/game-feel-on-the-web/)). 따라서 (a)를 먼저 배포하고 (b)는 `pixel-vfx-assets.md`에서 이미 소싱된 CC0 팩(카테고리 1/2/3/5)을 확보한 뒤 얹는 현재 계획 순서가 리서치 근거상으로도 합리적이다.
- **로스트아크식 "강화 단계별 상시 오라 색상 변화"는 (a)만으로 흉내 가능**하다 — `.hueRotation` 애니메이션으로 색을 단계별 프리셋에 스냅시키면 별도 스프라이트 에셋 없이도 "고강 장비/펫은 색이 다르다"는 신호를 줄 수 있다(설계 제안, 로스트아크가 실제로 hueRotation을 쓴다는 뜻은 아니며 원본은 별도 텍스처/파티클로 구현했을 가능성이 높음 — 결과물의 시각적 유사성만 차용하는 것을 권장).

---

## 1. 차지/기대(anticipation) — 강화 시도 순간 대상의 반응

### 사실

- **공격 애니메이션의 3단계 모델**(anticipation → attack → recovery)에서 anticipation의 목적은 "다음에 무슨 일이 일어날지 플레이어에게 신호를 주는 것"이며, 타이밍 공식으로 `anticipation time = 플레이어 반응시간(기본 0.25초, 30fps 기준 약 8프레임) + 기대되는 플레이어 반응 트리거 시간 + 난이도 버퍼`가 제시된다. 또한 "전투의 열기 속에서는 미묘한 디테일이 묻히므로, 다른 이펙트/포즈는 확연히 달라야 인지된다"는 원칙도 함께 제시된다.
  출처: [GDKeys — Keys to Combat Design: Anatomy of an Attack](https://gdkeys.com/keys-to-combat-design-1-anatomy-of-an-attack/) (게임 디자인 전문 블로그, 날짜 미상이나 다수 게임 개발자가 인용하는 자료 — 신뢰도 중상)
- **에너지 차지 연출의 일반 패턴**: 에너지 기반 공격의 anticipation 단계는 "캐릭터 손 주변에 에너지가 모이는(gather)" 형태로 묘사됨. 정확한 특정 게임 사례 인용은 검색 결과에서 확보하지 못함 — 정성적 일반화.
  출처: WebSearch 종합(개별 원문 미확인, 신뢰도 낮음—중간)
- **블링크 펄스(alpha 오실레이션) 기법**: 스프라이트의 alpha(투명도) 값을 최소~최대 사이에서 주기적으로 왕복시키는 경량 기법. 파라미터는 "최소 alpha"(예 0.3), "최대 alpha"(예 1.0), "초당 사이클 수"로 구성되며, 저자는 "마법 오라나 빛나는 버튼처럼 게임 오브젝트에 생동감을 주는 용도"로 이 기법을 예시함.
  출처: [funkyton.com — Unity "Blink Pulse" Sprite Animation](https://funkyton.com/unity-blink-fade-sprite/) (개인 게임개발 블로그, 신뢰도 중간)
- **슬롯머신의 "니어미스/기대감" 연출**: 릴이 느려지는 것, 긴장감 있는 사운드, 깜빡이는 애니메이션, 결과 지연이 결합되어 기대를 최대한 늘리도록 설계됨. 니어미스(거의 맞춘 조합) 발생 시 해당 심볼에 깜빡이는 테두리(flashing border)나 발광 효과(glowing effect)를 씌워 플레이어의 주의를 유도. 근거로 인용된 연구는 "니어미스가 실제 승리와 유사한 도파민 반응을 유발하며, 기대감 자체가 보상보다 더 자극적으로 느껴질 수 있다"는 신경과학적 주장.
  출처: [eternalslots.com — The Psychology Behind Near Misses in Slot Games](https://news.eternalslots.com/the-psychology-behind-near-misses-in-slot-games/), [arthouselabs.com — How Slot Games Create Emotional Feedback Through Visual Design](https://arthouselabs.com/blog/how-slot-games-create-emotional-feedback-through-visual-design) (카지노/도박 산업 블로그, 도박 심리 마케팅 목적의 글이라 과장 가능성 있음 — 신뢰도 중간, 특히 "도파민" 인과 주장은 일반화된 서술로 원 논문 직접 확인 못함)

### 확인 안 된 것 (이 단계)

- 메이플스토리 스타포스나 던파 강화·증폭에서 **강화 버튼을 누른 순간 장비/캐릭터 자체에 걸리는 "차지" 전용 시각효과**(예: 아이템에 에너지가 모여드는 연출)의 구체적 존재 여부는 이번 조사에서 직접 확인하지 못했다. 두 게임 공식 가이드 페이지(`maplestory.nexon.com/Guide/...`, `df.nexon.com/guide?no=710`)는 WebFetch 시 로그인 리다이렉트/402 오류로 원문 접근이 막혔고, WebSearch 요약도 "전체화면 연출"(성공/파괴 결과 시점)만 언급할 뿐 시도 직전 차지 연출은 언급하지 않았다. **"메이플/던파에 차지 연출이 없다"고 단정할 근거도 없다** — 단순히 이번 조사 범위에서 확인하지 못한 것으로 표기.

---

## 2. 성공 — 대상에 걸리는 플래시/팝/오라/스파클

### 사실

- **히트 플래시(hit-flash) 기법**: 스프라이트를 몇 프레임 동안 흰색(또는 다른 발광색)으로 틴트/플래시시키는 기법. Unity에서는 `c.rgb = lerp(c.rgb, _FlashColor.rgb, _FlashAmount)` 형태의 셰이더로 원래 색상과 플래시 색상을 보간하고, `SetFloat()`/`SetColor()`로 파라미터를 조절. Godot에서는 `uniform bool active` 토글로 흰색 오버레이(`vec4(1.0, 1.0, 1.0, alpha)`)를 씌우고 AnimationPlayer로 on/off 타이밍을 제어. GameMaker에서는 `shader_set()`으로 화이트아웃 셰이더를 적용해 "타이트한 1프레임 흰색 플래시"를 구현. 이 기법은 원래 "데미지를 받았다"는 신호(슈팅/비트엠업 장르)로 쓰이지만, 색상만 바꾸면(흰색→금색 등) 성공/보상 신호로 그대로 전용 가능하다는 것이 구조적으로 확인됨.
  출처: [Godot Shaders — Hit Flash Effect Shader](https://godotshaders.com/shader/hit-flash-effect-shader/), [Medium(Ilham Effendi) — Sprite Flash in Unity](https://ilhamhe.medium.com/sprite-flash-in-unity-b4b466f875d1), [GameDeveloper.com — Game Maker tutorial: Make your sprites flash!](https://www.gamedeveloper.com/programming/game-maker-tutorial-make-your-sprites-flash-)
- **스쿼시&스트레치(squash & stretch) / 스케일 팝**: 디즈니 12원칙에서 유래한 기법으로, 원래는 "튕기는 공이 충돌 시 납작해지고 반동 시 늘어나 무게/에너지를 표현"하는 원칙이었으나, 게임에서는 "충돌 시 스프라이트를 짧게 스케일링해 무게감을 전달"하는 용도로 재사용됨.
  출처: [valdemird.com — Game feel on the web: squash, shake, and the art of juice](https://valdemird.com/blog/game-feel-on-the-web/)
- **로스트아크(Lost Ark) 무기 강화 단계별 오라 색상 변화**(대상 자체에 상시 걸리는 성공 누적 시각효과 사례): 19강 = "찐핑크"(진분홍), 20강 = 하늘색+금색 조합, 21~22강 = 연핑크, 23~24강 = 주황+노랑(붉은 기 포함), 25강 = 흰색 대형 이펙트. 단계가 오를수록 이펙트 규모/화려함이 커지는 것으로 커뮤니티에서 정리됨.
  출처: [인벤 — 로스트아크 무기 강화 이펙트 19강~25강 정리](https://www.inven.co.kr/board/lostark/4811/2224161) (커뮤니티 공략 게시글, 스마일게이트/아마존게임즈의 1차 공식 확인은 못함 — 신뢰도 중간. 다만 강화수치별 무기 발광 색상이 존재한다는 것 자체는 로스트아크를 플레이해본 유저들 사이에서 널리 알려진 사실로, 수치의 정확한 단계 매핑만 커뮤니티 소스 기반)
- **메이플스토리**: 강화 연출은 화면 우하단에서 온오프 토글 가능. **20성 이상 강화 시(관련 업적이 없는 경우) 또는 25성 이상 강화 시(업적 유무와 무관하게)** 성공 또는 파괴 결과에 **전체화면 연출**이 추가됨(즉 대상만이 아니라 화면 전체가 반응). **스타포스 23성 이상인 장비는 인벤토리 툴팁 상단에 화려한 이펙트가 상시로 추가**되어, "이 장비는 고강이다"라는 시그널을 장비 아이콘/툴팁 자체가 지속적으로 낸다 — 이는 "강화 성공 순간"의 일회성 연출이 아니라 "보유 중 상시" 연출이라는 점에서 로스트아크의 "단계별 오라"와 유사한 카테고리(지속형 등급 표시). 또한 2021년 4월 22일 패치로 스타포스 강화 연출 시간이 약 80% 단축됨(반복 강화 시 텐포가 늘어지지 않도록 조정한 사례).
  출처: WebSearch 요약 경유 — [메이플스토리 공식 가이드(스타포스 강화)](https://maplestory.nexon.com/Guide/N23GameInformation/377418), [메이플스토리 인게임 가이드](https://maplestory.nexon.com/Guide/GameInformation/ItemEnhancement/StarforceEnforcement). **원문 직접 WebFetch는 실패**(전자는 302 리다이렉트 후 에러 페이지, 후자는 로그인 화면만 반환) — WebSearch 자동 요약에 의존, 축자 인용 아님. 신뢰도는 중간(공식 소스 기반이지만 원문 미대조).
- **세븐나이츠(Seven Knights) 각성(awakening) 캐릭터 반응**: 각성 게이지가 10 도달 시 캐릭터가 오오라(aura)를 내뿜고 고유 자세+이펙트를 연출하며 스킬 아이콘이 활성화됨. 초기 설계는 물리공격 캐릭터=주황 오라, 마법공격 캐릭터=보라 오라의 색상 이원화였으나, 이후 캐릭터마다 고유 색상 또는 반대색 오라로 다양화됨. 이는 "게이지 충족 → 캐릭터 자체가 시각적으로 달라짐(오라+포즈)"이라는 점에서 강화 성공과 유사한 "대상 자체 트랜스폼" 사례.
  출처: [나무위키 — 세븐나이츠](https://namu.wiki/w/%EC%84%B8%EB%B8%90%EB%82%98%EC%9D%B4%EC%B8%A0) (WebSearch 요약 경유, 커뮤니티 위키 — 신뢰도 중간)
- **포켓몬 진화(evolution) 애니메이션**(강화와는 다른 시스템이나 "대상이 결과에 반응해 극적으로 변형"하는 가장 유명한 참고 사례): 게임 스프라이트 버전은 "스프라이트가 흰색으로 페이드 → 진화 전/후 스프라이트가 번갈아 커졌다 작아졌다 하며 교차 → 진화된 스프라이트에 색이 채워짐(color fills in)" 순서로 진행된다고 서술됨. 1세대(Gen I) 한정으로는 "정면 스프라이트가 깜빡이는 실루엣(blinking silhouette)"으로 진화 중임을 표현. 애니메이션판(TV시리즈) 연출은 별도로 "밝은 색의 빛에 감싸이며 서서히 형태가 바뀐다"로 서술됨(이쪽은 Bulbapedia에서 직접 인용 확인됨).
  출처: 게임 스프라이트 버전 — WebSearch 요약 경유([essentialsdocs.fandom.com/wiki/Evolution](https://essentialsdocs.fandom.com/wiki/Evolution), [pokemonnj.fandom.com/wiki/Evolution/Animation](https://pokemonnj.fandom.com/wiki/Evolution/Animation)), **원문 직접 WebFetch는 모두 실패**(402/403 오류) — 신뢰도 중간, 축자 인용 아님. 애니메이션판 버전 — [Bulbapedia — Evolution](https://bulbapedia.bulbagarden.net/wiki/Evolution) 직접 WebFetch로 원문 인용 확인: *"When a Pokémon begins to evolve, it will be enveloped by a brightly colored light while slowly changing form."* — 신뢰도 높음(팬덤 위키 중 가장 편집 신뢰도가 높다고 알려진 Bulbapedia, 직접 인용 확보).

### 상충 정보

- 포켓몬 진화 애니메이션의 정확한 시퀀스 서술이 출처마다 다르다: (i) "흰색 페이드 → 스프라이트 교차 확대/축소 → 색 채우기"(essentialsdocs/pokemonnj, 게임 로직 관점), (ii) "밝은 빛에 감싸여 서서히 형태 변화"(Bulbapedia, 애니메이션판 관점). 이는 상충이라기보다 **게임 소프트웨어 구현 vs 애니메이션(TV판) 연출이라는 서로 다른 매체를 서술한 것**으로 판단되며, 게임 내 실제 스프라이트 구현 디테일은 신뢰도가 더 낮은(원문 미확인) 소스에만 있다는 점에 유의.

---

## 3. 실패/유지 — 대상 흔들림, 흐려짐

### 사실

- **던전앤파이터 "화면 흔들림 이펙트" 그래픽 옵션**: 시스템 옵션의 그래픽 설정에 "화면 흔들림 이펙트"가 있으며, 부드러운 흔들림 효과가 추가되어 기존 흔들림과 신규 흔들림 중 선택 적용 가능. **단, 이 옵션이 강화(장비 강화/증폭) 실패 시 구체적으로 발동되는지는 검색 스니펫만으로는 확인하지 못했다** — 원문(공식 그래픽 옵션 가이드)을 직접 열람하지 못해 "전투 타격 전반의 화면 흔들림 옵션"인지 "강화 UI 전용 연출"인지 구분이 안 됨.
  출처: WebSearch 요약 경유 — [df.nexon.com/community/news/update/2406716](https://df.nexon.com/community/news/update/2406716) (전투 액션 관련 그래픽 옵션 개선 및 추가), [df.nexon.com/community/dnfboard/article/2939872](https://df.nexon.com/community/dnfboard/article/2939872?category=1) (화면 설정) — **원문 미확인, 확인 강도 낮음**
- **셰이크(shake) 기법의 범용성**: 앞서 2번 항목의 hit-flash와 마찬가지로 shake는 "타격/데미지"의 범용 신호이며, 색을 붉은색/어두운 톤으로 바꾸면 "실패/아쉬움"의 신호로 전용 가능하다는 것이 구조적으로 뒷받침됨(직접 "강화 실패"에 적용한 특정 게임 사례는 확보하지 못했으나, 기법 자체의 범용성은 게임 개발 문헌에서 광범위하게 확인됨).
  출처: 2번 항목과 동일(Godot Shaders, Medium, GameDeveloper.com)
- **스크린셰이크 튜닝 가이드라인**: 스크린셰이크는 충격/무게감을 전달하는 용도로 사용하되 남발하지 말 것, 지속시간은 50~300ms로 짧게, 진폭은 시간에 따라 감쇠시킬 것, 회전을 살짝 추가하면(수십분의 1도 단위) "힘"으로 읽히고 과하면 "글리치"처럼 보임 — 이라는 튜닝 가이드가 다수 게임 개발 아티클에서 반복 확인됨.
  출처: [dawnosaur.substack.com — 7 Game Feel Tricks to Improve Your Game](https://dawnosaur.substack.com/p/7-game-feel-tricks-to-improve-your), [valdemird.com](https://valdemird.com/blog/game-feel-on-the-web/) (2차 정리 블로그, 원조는 Vlambeer의 "The Art of Screenshake"(2013, Jan Willem Nijman) 및 "Juice it or Lose it"(2012, Martin Jonasson & Petri Purho) 두 GDC/강연 자료로 커뮤니티에서 광범위하게 인용됨 — 강연 원본 슬라이드/영상은 이번 조사에서 직접 열람하지 못함, 2차 소스로만 확인)

---

## 4. 파괴/하락 — 대상 산산조각/그레이스케일/균열

### 사실

- **스프라이트 셔터(shatter) 이펙트**: 임팩트 지점에서 균열이 방사형으로 퍼져나간 뒤(cracks radiate outwards from an impact point) 스프라이트가 날카로운 조각(voronoi 또는 삼각형 프래그먼트)으로 쪼개지는 2단계 구조가 일반적. Unity에는 이를 위한 오픈소스 툴(`Explodable` 컴포넌트, `explode()` 호출 시 원본 스프라이트를 파괴하고 파편을 활성화)이 존재.
  출처: [GitHub — mjholtzem/Unity-2D-Destruction](https://github.com/mjholtzem/Unity-2D-Destruction) (오픈소스 프로젝트, 커뮤니티 툴 — 구현 방식 자체의 사실 확인 신뢰도 높음), 다수 YouTube 튜토리얼(예: "Destruction in Unity 2D - Shatter Effect on Any Sprite") — 정성적 서술
- **메이플스토리 파괴 시 전체화면 연출**: 2번 항목에서 확인한 것과 동일하게, **20성/25성 임계값 이상에서 "성공 또는 파괴 시" 전체화면 연출이 추가**된다 — 즉 메이플은 성공과 파괴를 같은 급의 "화면 전체가 반응하는 강한 연출"로 취급하며, 색상/톤(파괴=암울한 톤, 성공=화려한 톤 추정)으로 구분할 뿐 연출의 "규모"는 대칭적으로 설계된 것으로 보인다(추정 — 정확한 색상/구성 차이는 원문 미확인).
  출처: 2번 항목과 동일, WebSearch 요약 경유, 원문 미확인
- **그레이스케일/암전(darken)을 "파괴/하락"의 신호로 쓰는 것은 이번 조사에서 특정 상용 게임의 1차 사례로 직접 확인하지 못했다.** 다만 일반 UI 컨벤션에서 "비활성/손상된 아이템을 회색조로 표시"하는 것은 게임 UI 전반에서 흔한 패턴으로 통용되며(예: 인벤토리에서 사용 불가 아이템의 회색 처리), 이를 "강화 파괴의 순간적 애니메이션"으로 확장하는 것은 **리서처의 설계 제안(추정)**이지 특정 게임에서 확인된 사실은 아니다.

### 확인 안 된 것 (이 단계)

- 던전앤파이터의 장비 파괴(무기 +12↑, 방어구 +10↑) 순간 **장비 아이콘/캐릭터 자체에 걸리는 구체적 시각 이펙트**(파편, 암전, 사운드와의 동기화 등)는 이번 조사에서 확인하지 못했다. `dnf-enhancement.md`가 이미 확률/리스크 구조를 다뤘고, 이번 조사는 df.nexon.com 공식 가이드 원문(no=710, 1230)에 WebFetch로 접근하지 못해(과거 조사에서도 동일하게 AI 요약 경유만 가능했다는 기록이 `dnf-enhancement.md`에 있음) 시각 연출 세부까지는 도달하지 못했다.
- 로스트아크의 강화 **실패** 시 무기 자체 반응(흔들림/암전 여부) — 이번 조사는 성공 시 오라 색상 변화만 확보, 실패 시 반응은 미조사.

---

## 5. (a) 네이티브 스프라이트 변형 vs (b) 오버레이 VFX 자산 분류

| 연출 | 분류 | 근거/기법 | 구현 난이도(추정) |
|---|---|---|---|
| 발광 펄스(alpha 오실레이션) | **(a) 네이티브** | 블링크 펄스 기법 — alpha min/max 왕복 (funkyton.com) → SwiftUI `.opacity()` + `withAnimation(.repeatForever)` | 낮음 |
| 진동/떨림(shake) | **(a) 네이티브** | `GeometryEffect` 기반 sin 변형(objc.io, WWDC21) → SwiftUI 표준 패턴 | 낮음 |
| 색조 변화(성공=밝은색, 실패=어두운색, 단계별 오라색) | **(a) 네이티브** | hit-flash 기법(색 lerp/오버레이)의 색상 확장, 로스트아크식 단계별 색상 프리셋 아이디어 차용 → SwiftUI `.hueRotation()`, `.brightness()` | 낮음 |
| 그레이스케일/채도 저하(파괴·하락) | **(a) 네이티브** | UI 컨벤션(비활성 아이템 회색 처리)의 애니메이션 확장 → SwiftUI `.grayscale()`, `.saturation()` | 낮음 |
| 스케일 팝/스쿼시&스트레치(성공 임팩트) | **(a) 네이티브** | 디즈니 12원칙 → 게임 juice 관행(valdemird.com) → SwiftUI `.scaleEffect()` + spring/overshoot 애니메이션 | 낮음~중간(오버슈트 이징 튜닝 필요) |
| 회전/기울임(붕괴 느낌) | **(a) 네이티브** | 스크린셰이크의 "약간의 회전 추가" 가이드라인 응용 → SwiftUI `.rotationEffect()` | 낮음 |
| 흰색/금색 플래시(성공 순간) | **(a) 네이티브에 근접, 다만 (b)로 하면 더 화려**함 | hit-flash 셰이더 기법(Godot/Unity) — SwiftUI는 픽셀 셰이더 접근이 제한적이라 완전히 동일 재현은 어려움. 대안으로 반투명 흰색 오버레이 `Rectangle().opacity()` + blendMode를 얹는 절충 가능 | 중간 |
| 지속형 등급 오라(로스트아크식 강화단계별 색) | **(a) 네이티브로 흉내 가능** | hueRotation 프리셋 스냅 방식(설계 제안) | 낮음~중간 |
| 폭발/타격 버스트 | **(b) 에셋 필요** | `pixel-vfx-assets.md` 카테고리 1 — CodeManu, BenHickling(CC0) | 중간(에셋 통합 작업) |
| 충격파 링(성공 강조) | **(b) 에셋 필요** | `pixel-vfx-assets.md` 카테고리 5 — BenHickling Ring Explosion(CC0) | 중간 |
| 스파클/별(성공 반짝임) | **(b) 에셋 필요** | `pixel-vfx-assets.md` 카테고리 2 — GrafxKid Mini FX(CC0) | 중간 |
| 마법진/오라 파티클(차지) | **(b) 에셋 필요** | `pixel-vfx-assets.md` 카테고리 3 — Foozle Pixel Magic Effects(CC0) | 중간 |
| 파편/산산조각(파괴) | **(b) 에셋 필요(또는 절차적 생성)** | Unity 2D Destruction류 절차적 파편화는 SwiftUI/펫 스프라이트 파이프라인에 이식하기엔 과함 — 사전 제작된 파편 스프라이트 오버레이가 현실적 | 높음(직접 파편화는 비권장, 사전 제작 에셋 권장) |
| 연기/먼지(파괴 마무리) | **(b) 에셋 필요** | `pixel-vfx-assets.md` 카테고리 2/4 — GrafxKid Mini FX(cloud poof, CC0) | 중간 |

**분류 원칙(리서치 기반 일반화, 추정 포함)**: 색/투명도/크기/회전처럼 "스프라이트의 기존 픽셀을 그대로 두고 변환(transform)만 가하는" 연출은 전부 (a)로 가능하다. 반대로 "스프라이트에 없던 새로운 픽셀(불꽃, 파편, 별, 링)을 화면에 추가로 그려야 하는" 연출은 전부 (b)가 필요하다 — 이 구분은 셰이더/변환 vs 파티클/스프라이트 오버레이라는 게임 그래픽스의 근본적 이분법과 일치하며, 이번 조사에서 확인한 모든 개별 기법 사례가 이 구분을 벗어나지 않았다.

---

## 우리 강화소 적용안 (설계 제안 — 사실이 아니라 권장, 추정 다수 포함)

펫 강화 화면의 단계를 **대기(idle) → 차지(강화 버튼 클릭 직후~결과 직전) → 결과(성공/실패·유지/강등/파괴)** 4단으로 보고 제안한다. 강화 단계(낮은 단계 vs 높은 단계·희귀도)에 따라 연출 강도를 계단식으로 올리는 것은 메이플(20성/25성 임계값 전체화면 연출)과 로스트아크(강화단계별 오라 색상 확대) 사례에서 공통으로 확인된 패턴이므로, 우리도 "저강 펫 강화는 (a)만, 고강/고레어리티는 (a)+(b)"로 나누는 것을 권장한다.

### 차지 (버튼 클릭 → 결과 발표 직전)

- **(a) 네이티브 (우선 구현)**: 펫 스프라이트에 `.opacity()` 블링크 펄스(0.7↔1.0, 초당 2~3사이클, funkyton.com 패턴) + 미세한 `.scaleEffect()` 진동(1.0↔1.03) 조합으로 "긴장감/에너지 축적"을 표현. 강화 단계가 높을수록(또는 희귀 펫일수록) 펄스 주기를 빠르게 해 "위험도가 높다"는 신호를 함께 줄 수 있다(설계 제안, 특정 게임에서 확인된 패턴은 아님).
- **(b) 에셋 (후행)**: `pixel-vfx-assets.md` 카테고리 3(Foozle Pixel Magic Effects)의 차지형 이펙트(Portal 등)를 펫 발밑에 루프 재생 — 슬롯머신의 "니어미스 서스펜스" 연출처럼 결과 직전 잠깐 애니메이션 재생 속도를 늦추는 것도 고려 가능(추정 제안, 근거는 도박 심리 문헌의 일반화이지 특정 강화 게임 사례는 아님 — 사용 시 신중히).

### 성공

- **(a) 네이티브 (우선 구현)**: hit-flash 기법을 색만 바꿔 재사용 — 짧은(1~2프레임 상당, 약 0.1초) 흰색/금색 오버레이 플래시 + `.scaleEffect()` 스케일 팝(1.0→1.15→1.0, spring 이징으로 오버슈트) 조합. 강화 성공이 누적될수록(또는 고단계 진입 시) `.hueRotation()`으로 펫에 상시 색조 프리셋을 스냅시켜 "이 펫은 강화 단계가 높다"를 로스트아크식으로 표현하는 것도 고려 가능(설계 제안).
- **(b) 에셋 (후행)**: `pixel-vfx-assets.md` 카테고리 1/2/5(CodeManu 폭발, GrafxKid 스파클, BenHickling Ring Explosion)를 펫 주변에 오버레이. 규모는 강화 단계에 비례해 키운다(메이플의 "23성 이상만 화려한 이펙트" 패턴 차용).

### 실패/유지

- **(a) 네이티브 (우선 구현)**: 강도를 낮춘 shake(짧은 지속시간 100~150ms, 진폭 작게, GeometryEffect sin 패턴) + 짧은 `.opacity()` 딤(0.8로 살짝 어두워졌다 복귀) 조합. 색은 붉은 계열보다 무채색/차분한 톤(hueRotation 살짝 낮춤)으로 "아쉬움"을 표현해 파괴와 명확히 구분되도록 한다.
- **(b) 에셋 (선택)**: 필요성 낮음. 넣는다면 작은 스파크/먼지 puff 정도(GrafxKid Mini FX 겸용)만 가볍게.

### 강등/파괴

- **(a) 네이티브 (우선 구현)**: `.grayscale(1.0)`으로 점진 전환(0.3~0.5초에 걸쳐) + `.scaleEffect()` 축소(0.9) + `.rotationEffect()` 살짝 기울임(붕괴감) + `.opacity()` 감소(0.5 내외) + 강한 shake(진폭 크게, 지속시간 200~300ms, 스크린셰이크 튜닝 가이드라인의 상한 근처)를 조합. 강한 shake에는 스크린셰이크 가이드라인처럼 약간의 회전을 섞으면 "힘"으로 읽힌다는 문헌 근거가 있다.
- **(b) 에셋 (후행)**: 파괴 전용 폭발(어두운 톤으로 재채색한 CodeManu/BenHickling 폭발) 또는 사전 제작 파편 스프라이트 오버레이. 절차적 실시간 파편화(Unity 2D Destruction류)는 SwiftUI/펫 렌더링 파이프라인과 궁합이 나빠 비권장 — 사전 제작된 "깨지는 알/조각" 스프라이트를 쓰는 편이 현실적(설계 제안).

**공통 원칙(제안)**: 낮은 강화 단계·일반 펫은 (a)만으로 충분히 "밋밋하지 않게" 만들고, 고강화 단계·희귀 펫으로 갈수록 (b) 오버레이를 추가해 "이건 특별하다"는 차등 신호를 준다 — 이는 메이플/로스트아크에서 공통으로 관찰된 "저단계 담백, 고단계 화려" 계단식 설계와 궤를 같이한다.

---

## 확인 안 된 것 (전체)

- 메이플스토리 스타포스, 던전앤파이터 강화·증폭의 **"강화 시도 버튼을 누른 직후~결과 발표 직전" 구간에 대상(장비) 자체에 걸리는 전용 차지 연출**의 존재 여부 — 공식 가이드 원문(로그인 필요/402/302 오류)에 접근하지 못해 확인 실패.
- 로스트아크 강화 **실패** 시 무기 자체의 시각 반응(흔들림/암전 유무) — 이번 조사는 성공 시 색상 변화만 확보.
- 던전앤파이터 "화면 흔들림 이펙트" 옵션이 **강화 실패 UI**에 실제로 연동되는지, 아니면 전투 타격 전반에만 적용되는 옵션인지 — 원문 미확인.
- 포켓몬 진화 애니메이션의 **게임 소프트웨어 구현 디테일**(정확한 프레임 순서, 스케일 값) — essentialsdocs/pokemonnj 원문 접근 실패(402/403), WebSearch 요약에만 의존.
- 젠신 임팩트(원신) 캐릭터 돌파(ascension) 시 캐릭터 자체의 시각 반응 — 검색 결과가 "돌파 재료"/"실루엣 공개(신캐 티저)" 위주로만 나와 이번 조사 범위에서 확보하지 못함(참고 자료로만 남김).
- SwiftUI에서 실제로 픽셀 셰이더 수준의 정교한 hit-flash(색상 완전 치환)를 구현할 수 있는지 — `.hueRotation`/`.brightness`/반투명 오버레이 조합으로 근사는 가능하나, Unity/Godot 예제처럼 셰이더 레벨에서 원본 알파를 보존한 완전한 색상 치환이 SwiftUI 표준 API만으로 동일하게 재현되는지는 실제 구현 시점에 별도 검증 필요(이번 조사는 API 존재만 확인, 픽셀 단위 동작 검증은 안 함).

## 참고 자료 (미확인이지만 후속 조사 가치 있음)

- [df.nexon.com/guide?no=710](https://df.nexon.com/guide?no=710), [no=1230](https://df.nexon.com/guide?no=1230) — 던파 공식 강화 가이드 원문. `dnf-enhancement.md`에서도 AI 요약 경유로만 접근된 것으로 기록되어 있어, 시각 연출 세부까지 다루려면 원문 스크린샷/직접 플레이 확인이 필요.
- [maplestory.nexon.com/Guide/N23GameInformation/377418](https://maplestory.nexon.com/Guide/N23GameInformation/377418) — 리다이렉트 오류로 접근 실패. URL 구조가 최근 개편되었을 가능성, 최신 URL 재탐색 필요.
- Vlambeer "The Art of Screenshake"(Jan Willem Nijman, 2013), "Juice it or Lose it"(Martin Jonasson & Petri Purho, 2012) — 게임 feel/juice 논의의 원조 GDC/강연 자료. 이번 조사는 2차 요약 블로그로만 인용했고 원본 영상/슬라이드는 열람하지 못함. YouTube에 두 강연 모두 공개되어 있는 것으로 알려짐(재생목록: [Fave Game Talks (Juice and Game Feel)](https://www.youtube.com/playlist?list=PL2gEO25pE6dqsPxgajrZSuqutgzZSjnk5)).
- [objc.io — SwiftUI: Shake Animation](https://www.objc.io/blog/2019/10/01/swiftui-shake-animation/) — SwiftUI GeometryEffect 기반 shake 구현의 원 소스로 추정(WebSearch 요약으로만 확인, 원문 직접 열람 못함). 실제 구현 시 원문 대조 권장.
- [genshin-impact.fandom.com/wiki/Character/Ascension](https://genshin-impact.fandom.com/wiki/Character/Ascension) — 원신 돌파 시스템 문서, 시각효과 서술 여부는 미확인.
- [chuchu.gg/starforce](https://chuchu.gg/starforce) — 메이플 강화 히스토리/통계 사이트, 연출 관련 스크린샷 존재 가능성(미확인).
