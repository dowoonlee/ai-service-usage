# AI Usage

Claude.ai(Max/Pro)와 Cursor(Ultra/Pro) 구독 사용량을 **항상 떠있는 작은 플로팅 윈도우**로 보여주는 macOS 앱.

- Claude: 5시간창 %, 주간 %, 리셋 카운트다운, 자체 스파크라인
- Cursor: 월 누적 $ (Ultra) / 요청수 (Pro), 리셋 카운트다운, 이번 달 이벤트 기반 누적 그래프
- 플랜 자동 감지(예: `Max 20x`, `Ultra`)하여 헤더 배지 표시
- 섹션별 접기/펴기, 80% 이상 빨간색 경고

## 설치

**요구사항**: macOS 14(Sonoma) 이상

1. 다운로드
   - [최신 릴리스 zip 바로 받기](https://github.com/dowoonlee/ai-service-usage/releases/latest/download/AIUsage.zip)
   - 또는 [Releases 페이지](https://github.com/dowoonlee/ai-service-usage/releases/latest)에서 수동 다운로드
2. `AIUsage.zip` 더블클릭 → `AIUsage.app` 생성
3. `AIUsage.app`을 `/Applications` 폴더로 드래그 (또는 원하는 위치)

### 첫 실행 (unsigned 앱 Gatekeeper 우회)

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
- 의존성 없음 (SwiftPM 표준 toolchain)
