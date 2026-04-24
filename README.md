# Claude Usage Widget

Claude.ai(Max/Pro)와 Cursor(Ultra/Pro) 구독 사용량을 **항상 떠있는 작은 플로팅 윈도우**로 보여주는 macOS 앱.

- Claude: 5시간창 %, 주간 %, 리셋 카운트다운, 자체 스파크라인
- Cursor: 월 누적 $ (Ultra) / 요청수 (Pro), 리셋 카운트다운, 이번 달 이벤트 기반 누적 그래프
- 플랜 자동 감지(예: `Max 20x`, `Ultra`)하여 헤더 배지 표시
- 섹션별 접기/펴기, 80% 이상 빨간색 경고

## 설치

1. [Releases](../../releases)에서 최신 `ClaudeUsage.zip` 다운로드
2. `.zip` 더블클릭 → `ClaudeUsage.app` 나옴
3. `/Applications`로 드래그 (또는 원하는 위치)
4. **첫 실행**: Finder에서 `ClaudeUsage.app` **우클릭 → Open → Open anyway**
   - 서명되지 않은 앱이라 Gatekeeper 경고가 뜹니다. 한 번만 이렇게 열면 이후 더블클릭으로 동작.

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
