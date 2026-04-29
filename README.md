# AI Usage

Claude.ai(Max/Pro)와 Cursor(Ultra/Pro) 구독 사용량을 **항상 떠있는 작은 플로팅 윈도우**로 보여주는 macOS 앱.

- Claude: 5시간창 %, 주간 %, 리셋 카운트다운, 자체 스파크라인
- Cursor: 월 누적 $ (Ultra) / 요청수 (Pro), 리셋 카운트다운, 이번 달 이벤트 기반 누적 그래프
- 플랜 자동 감지(예: `Max 20x`, `Ultra`)하여 헤더 배지 표시
- 사용 페이스 예측: 현재 속도로 가면 리셋 전 몇 %에 도달할지 / 한도까지 남은 시간
- 임계치 알림: 80% / 95% 도달 시 macOS 알림 (주기당 1회)
- **펫 가챠 컬렉션** (v0.2.0): 30종 픽셀 펫 + 4단계 색상 변종(이로치). 사용량이 코인으로 자동 적립되고 1주일에 약 2번 가챠를 돌릴 수 있음. 포켓몬 스타일 알 부화 연출. 차트 위에서 보유 펫이 걷고, 사용량에 따라 신나거나 불안해함.
- 펫 휴식 권유: 1시간 연속 사용 시 펫이 휴식 권유 말풍선. 1분 이내 클릭하면 +30 코인 보상 + 코인 popping
- 설정 패널: 창 투명도, 알림/페이스 표시 토글, 보유 펫 선택
- 섹션별 접기/펴기, 80% 이상 빨간색 경고
- Sparkle 기반 자동 업데이트

## 설치

**요구사항**: macOS 14(Sonoma) 이상

### Homebrew (권장)

```bash
brew install --cask dowoonlee/tap/aiusage
```

- 처음 실행 시 tap이 등록되고 cask가 설치됩니다 (별도 `brew tap` 불필요).
- Tap 포뮬라가 quarantine 속성을 자동 제거해서 **Gatekeeper 우회 단계 없이 바로 실행**됩니다.
- 업데이트: `brew upgrade --cask aiusage`

### 수동 설치

1. 다운로드
   - [최신 릴리스 zip 바로 받기](https://github.com/dowoonlee/ai-service-usage/releases/latest/download/AIUsage.zip)
   - 또는 [Releases 페이지](https://github.com/dowoonlee/ai-service-usage/releases/latest)에서 수동 다운로드
2. `AIUsage.zip` 더블클릭 → `AIUsage.app` 생성
3. `AIUsage.app`을 `/Applications` 폴더로 드래그 (또는 원하는 위치)

#### 첫 실행 (unsigned 앱 Gatekeeper 우회)

이 앱은 Apple Developer 서명이 없어서 최초 1회 macOS 보안을 우회해야 합니다. 아래 순서대로 진행하세요.

1. `AIUsage.app`을 더블클릭(또는 우클릭 → Open)합니다.
2. "**Apple은 'AIUsage'에 ... 악성 코드가 없음을 확인할 수 없습니다**" 같은 메시지가 뜹니다. **완료**(또는 **Done**)로 창을 닫습니다.
3. **시스템 설정**(Apple 메뉴 → System Settings) 을 엽니다.
4. 좌측 메뉴에서 **개인정보 보호 및 보안**(Privacy & Security) 선택.
5. 스크롤을 내리면 **"AIUsage가 확인되지 않은 개발자의 앱이므로 사용이 차단되었습니다"** 문구와 함께 오른쪽에 **그래도 열기**(Open Anyway) 버튼이 보입니다. 클릭.
6. Touch ID 또는 관리자 암호로 인증.
7. 확인 다이얼로그에서 **열기**(Open) 클릭 → 플로팅 창이 뜹니다.
8. 이후에는 더블클릭만으로 정상 실행됩니다.

> 차단 문구와 "그래도 열기" 버튼은 앱을 **한 번 실행 시도한 후**에만 표시됩니다. 1번 단계를 먼저 해야 5번이 보여요.

**터미널에 익숙하신 경우**: 아래 한 줄로 같은 효과를 낼 수 있습니다 (quarantine 속성 제거).
```bash
xattr -dr com.apple.quarantine /Applications/AIUsage.app
```

### 업데이트

- Homebrew 설치: `brew upgrade --cask aiusage`
- 수동 설치: 앱이 Sparkle로 하루 1회 자동 체크. 메뉴 `…` → "업데이트 확인…"으로 즉시 확인 가능.

## 사용

**Claude**
- 첫 실행 시 플로팅 창의 "로그인" 버튼 클릭 → 내장 브라우저로 claude.ai 로그인
- 세션 쿠키(`sessionKey`)는 macOS **Keychain**에 저장됨
- 5분마다 자동 폴링

**Cursor**
- Cursor 앱이 설치·로그인된 상태면 **자동 연동** (별도 로그인 불필요)
- Cursor 로컬 DB에서 JWT를 읽어 `cursor.com` 내부 API를 호출

데이터는 모두 로컬(`~/Library/Application Support/ClaudeUsage/`)에만 저장됩니다.

## 주의

이 앱은 Anthropic과 Cursor의 **비공식 엔드포인트**를 사용합니다. 두 회사가 API 구조를 변경하면 일부 또는 전체 기능이 멈출 수 있습니다. TOS상 회색지대이므로 자기 책임으로 사용하세요.

## 개발

```bash
swift run                    # 개발 실행
bash scripts/package.sh      # 릴리스 .app + .zip 생성 → dist/
```

- macOS 14+, Swift 5.9+
- 의존성: [Sparkle](https://sparkle-project.org) (자동 업데이트)

### 릴리스 절차

`v0.1.2` 형식의 태그를 push하면 `.github/workflows/release.yml`이:
1. `swift build -c release` → `.app` + `.zip` 생성
2. GitHub Release 생성 + zip 업로드
3. (Secret 설정 시) `appcast.xml`에 EdDSA 서명된 새 항목 prepend → main에 push
4. (Secret 설정 시) `dowoonlee/homebrew-tap` 의 cask 버전·sha256 자동 갱신

#### 처음 한 번: 키와 Secret 준비

1. Sparkle EdDSA 키 생성 (한 번만):
   ```bash
   swift build                                 # Sparkle 다운로드를 위해
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   public key를 출력해서 `SU_PUBLIC_KEY` 환경변수로 사용. private key는 keychain에 저장됨 — `generate_keys -x private.pem`로 export.

2. GitHub repo Settings → Secrets and variables → Actions → Secrets에 등록:
   - `SU_PUBLIC_KEY`: public key 문자열 (앱 Info.plist에 박힘)
   - `SU_PRIVATE_KEY`: private key 문자열 (appcast.xml 서명용)
   - `HOMEBREW_TAP_TOKEN` (선택): `dowoonlee/homebrew-tap` 푸시 권한이 있는 PAT

3. tap repo 만들기: `homebrew/README.md` 참고.

#### 매 릴리스

```bash
git tag v0.1.2 && git push origin v0.1.2
```

## 변경 이력

| 버전 | 날짜 | 주요 변경 |
|---|---|---|
| v0.2.1 | 2026-04-29 | 윈도우 경계에 폴링이 끼면 마지막 사용분이 코인 적립에서 누락되던 버그 수정 (resetAt 직전에 폴링 한 번 더 잡힘) |
| v0.2.0 | 2026-04-29 | 펫 가챠 컬렉션. 30종 펫 + 4단계 색상 변종(이로치), 사용량 비례 코인 적립, 알 부화 연출, 등급별 도감 |
| v0.1.14 | 2026-04-28 | 펫 휴식 권유 말풍선; 펫 hover 리액션 + 도망; AAAH/WHEE 임계치 슬라이더 |
| v0.1.13 | 2026-04-28 | 메뉴바 모드 토글; TUI 모드 (`--tui`) |
| v0.1.12 | 2026-04-28 | 펫 명언 확장; 펫·차트 코드 리팩터 |
| v0.1.11 | 2026-04-28 | Pixel Adventure 캐릭터 4종 추가 |
| v0.1.10 | 2026-04-27 | 큰 상승 시 점프 + "WHEE!"; quote 말풍선 plot 클램프 |
| v0.1.9 | 2026-04-27 | 펫이 가끔 멈춰 한국어 한 마디 |
| v0.1.8 | 2026-04-27 | v0.1.7 launch 크래시 hotfix |
| v0.1.7 | 2026-04-27 | 차트 위 픽셀 펫 6종 + 사용량 mood + "AAAH!" |
| v0.1.6 | 2026-04-27 | 접힌 섹션 헤더에 비례 게이지 |
| v0.1.5 | 2026-04-27 | 사용자 정의 알림 임계치 + 스파크라인 점선 |
| v0.1.4 | 2026-04-27 | 로그인 시 자동 시작 (`SMAppService`) |
| v0.1.3 | 2026-04-27 | Sparkle dyld 로드 경로 수정 |
| v0.1.2 | 2026-04-27 | 릴리스 파이프라인 portability 수정 |
| v0.1.1 | 2026-04-24 | 앱 이름 변경: ClaudeUsage → AI Usage |
| v0.1.0 | 2026-04-24 | 첫 릴리스 |
