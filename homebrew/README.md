# Homebrew tap 설정

이 폴더의 `aiusage.rb`는 [Homebrew Cask](https://github.com/Homebrew/homebrew-cask) 포뮬라 템플릿입니다.

## 처음 한 번: tap repo 만들기

1. GitHub에서 새 repo 생성: `dowoonlee/homebrew-tap` (이름 형식 고정)
2. clone 후 `Casks/` 폴더 만들고 `aiusage.rb` 복사
   ```bash
   git clone https://github.com/dowoonlee/homebrew-tap.git
   cd homebrew-tap
   mkdir -p Casks
   cp <이 repo>/homebrew/aiusage.rb Casks/aiusage.rb
   git add . && git commit -m "Add aiusage cask" && git push
   ```

## 사용자 설치

```bash
brew install --cask dowoonlee/tap/aiusage
```

## 릴리스 시 cask 업데이트

`.github/workflows/release.yml` 워크플로가 GitHub Release 생성 후
`HOMEBREW_TAP_TOKEN` Secret이 설정돼 있으면 tap repo에 자동 커밋합니다.

수동으로 할 경우:
```bash
VERSION=0.1.2
SHA=$(curl -sL https://github.com/dowoonlee/ai-service-usage/releases/download/v${VERSION}/AIUsage.zip | shasum -a 256 | awk '{print $1}')
# Casks/aiusage.rb의 version, sha256을 갱신해서 커밋
```
