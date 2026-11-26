# VJDeck 버전 올리기와 릴리스 배포

macOS 앱 버전은 [`scripts/release.sh`](../scripts/release.sh)로 올립니다. 배포할 버전의 변경 이력을 먼저 작성하고 `main`에 반영한 뒤, 미리보기를 확인하고 릴리스를 실행하세요.

실제 실행은 버전 변경, Release 빌드, 커밋과 태그 푸시, 공개 GitHub Release 업로드까지 한 번에 수행합니다. `--dry-run`은 파일을 바꾸거나 배포하지 않고 예정된 버전과 파일 이름을 보여줍니다.

## 올릴 버전 선택

현재 버전이 `1.5.4`인 경우의 예입니다. 아래 명령 중 배포할 버전에 맞는 하나를 사용하세요.

| 명령 | 결과 버전 | 용도 |
| --- | --- | --- |
| `scripts/release.sh patch` | `1.5.5` | 버그 수정과 작은 개선 |
| `scripts/release.sh minor` | `1.6.0` | 기능 추가 |
| `scripts/release.sh major` | `2.0.0` | 큰 변경 |
| `scripts/release.sh 1.6.2` | `1.6.2` | 버전을 직접 지정 |

버전은 `숫자.숫자.숫자` 형식이어야 하며 현재 버전보다 커야 합니다. 각 숫자에는 불필요한 앞자리 `0`을 붙이지 않습니다. `1.6.0-beta.1` 같은 사전 릴리스 형식은 지원하지 않습니다.

현재 버전은 저장소 루트에서 확인합니다.

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist
```

두 값은 같아야 합니다. 릴리스 스크립트가 두 값을 함께 변경하므로 배포 전에 `Info.plist`를 다음 버전으로 미리 올릴 필요는 없습니다.

## 처음 배포할 때 준비

[빌드 환경](../README.md#빌드)에 맞는 Apple Silicon Mac, macOS 15.4 이상, Xcode 16.3 이상과 XcodeGen 2.40 이상이 필요합니다. GitHub CLI도 설치하고 로그인합니다.

```bash
brew install gh xcodegen
gh auth login
gh auth status
```

현재 계정과 인증 토큰에는 이 저장소의 `origin`에 `main`과 태그를 푸시할 권한, 배포 저장소 `vjdeck/app`과 미러 저장소 `vjdeck/site`에 릴리스를 만들고 파일을 올릴 권한이 필요합니다. `main`의 보호 규칙이 직접 푸시를 막으면 스크립트의 버전 커밋 푸시도 실패합니다.

빌드 준비와 [TESTING.md](../TESTING.md)의 검증을 마친 뒤 배포하세요. 최초 빌드 준비 명령은 다음과 같습니다.

```bash
./scripts/bootstrap.sh
xcodegen generate
```

생성된 프로젝트에 변경이 있으면 앱 변경사항과 함께 커밋하고 `main`에 반영합니다.

## 변경 이력 작성

`CHANGELOG.md`의 맨 위에 배포할 버전의 섹션을 추가합니다. `1.5.5`를 배포한다면 다음과 같이 작성합니다.

```markdown
## [1.5.5] - 2026-10-09

### 추가
- 앱 종료 시 새 버전을 설치하는 자동 업데이트 기능 추가

### 수정
- 업데이트 설치 중 기존 앱이 손상될 수 있는 문제 수정
```

날짜와 내용은 실제 배포에 맞게 작성하세요. `patch`를 사용할 때도 다음 버전 번호에 맞는 섹션이 있어야 합니다. 스크립트는 이 섹션의 본문을 GitHub 릴리스 노트로 사용하며, 섹션이 없거나 본문이 비어 있으면 미리보기 단계부터 중단합니다.

앱 변경사항과 변경 이력을 커밋하고 `main`에 병합합니다. 버전 변경 커밋은 릴리스 스크립트가 따로 만듭니다.

## 미리보기와 실제 배포

저장소 루트에서 최신 `main`으로 이동합니다. 작업 중인 변경사항은 먼저 커밋해 두세요.

```bash
git switch main
git pull --ff-only origin main
git status --short
```

`git status --short`에 출력이 없어야 합니다. 스크립트는 추적 파일의 수정과 추적되지 않은 파일이 있는지 확인하고, 로컬 `main`과 `origin/main`이 같은 커밋인지 검사합니다.

다음 버전과 배포 파일 이름을 미리 확인합니다.

```bash
scripts/release.sh patch --dry-run
```

미리보기에는 다음 버전, 커밋 메시지, 태그, 공개 릴리스 주소와 첨부 파일 이름이 나옵니다. 미리보기는 로그인 상태, 쓰기 권한, 브랜치 상태나 빌드 성공 여부까지 검사하지 않습니다.

예정된 버전이 맞으면 같은 명령에서 `--dry-run`을 제거합니다.

```bash
scripts/release.sh patch
```

버전을 직접 지정할 때는 다음과 같이 실행합니다.

```bash
scripts/release.sh 1.6.0 --dry-run
scripts/release.sh 1.6.0
```

실제 실행은 다음 순서로 진행됩니다.

1. 로그인, 배포 저장소 쓰기 권한, 깨끗한 `main`, 원격과의 일치, 태그와 릴리스 중복을 검사합니다.
2. `Resources/Info.plist`의 두 버전 값을 변경합니다.
3. `scripts/build-dmg.sh`로 arm64 Release 앱을 빌드하고 ad-hoc 서명을 검증한 뒤 DMG를 만듭니다.
4. 자동 업데이트용 ZIP을 만듭니다.
5. `Bump version to vVERSION` 커밋과 `vVERSION` 태그를 만들고 이 저장소의 `origin`에 함께 푸시합니다.
6. `vjdeck/app`에 공개 릴리스를 만들고 DMG, ZIP과 변경 이력을 올립니다.
7. 같은 파일과 변경 이력으로 `vjdeck/site`에도 릴리스를 만듭니다. 1.8.0 이하 앱은 이 저장소에서 업데이트를 확인하므로, 미러 릴리스를 거쳐 `vjdeck/app`을 확인하는 버전으로 넘어옵니다.

버전만 변경하고 멈추는 실행 옵션은 없습니다. 실제 명령은 공개 배포까지 진행합니다.

## 배포 결과 확인

`1.5.5`를 배포한 경우 생성 파일은 다음과 같습니다.

| 경로 | 용도 |
| --- | --- |
| `build/release/VJDeck.dmg` | 사용자가 직접 설치할 파일 |
| `build/release/VJDeck-1.5.5.zip` | 앱이 자동 업데이트에 사용할 파일 |
| `build/release/notes-1.5.5.md` | GitHub에 올린 릴리스 노트 |
| `build/DerivedData/Build/Products/Release/VJDeck.app` | 빌드한 앱 |

성공하면 마지막에 `Published https://github.com/vjdeck/app/releases/tag/v1.5.5`와 `Published https://github.com/vjdeck/site/releases/tag/v1.5.5`가 출력됩니다. 두 공개 릴리스의 파일과 태그를 확인합니다.

```bash
gh release view v1.5.5 -R vjdeck/app
gh release view v1.5.5 -R vjdeck/site
git show --stat v1.5.5
git status --short
```

두 공개 릴리스에는 `VJDeck.dmg`와 `VJDeck-1.5.5.zip`이 모두 있어야 합니다. ZIP 안의 앱 이름은 `VJDeck.app`, 앱 버전은 `1.5.5`, 번들 ID는 `com.bada.VJDeck`이어야 합니다. 이 이름과 값은 스크립트와 빌드 설정이 맞추므로 수동으로 바꾸지 않습니다.

자동 업데이트 기능이 포함된 Release 앱은 실행할 때 새 버전을 확인합니다. `/Applications` 또는 `~/Applications` 바로 아래의 쓰기 가능한 설치본은 ZIP을 다운로드하고, 종료할 때 설치하거나 Settings → General → Restart to Update로 설치합니다. 설치가 불가능하거나 실패하면 수동 다운로드 링크를 표시합니다.

이 기능이 없는 기존 앱은 자동 업데이트 기능이 포함된 버전을 한 번 수동으로 설치해야 합니다. 개발 빌드 폴더에서 실행하는 Release 앱은 자동 교체되지 않습니다.

중단된 다운로드와 설치 작업은 다음 앱 실행에서 정리합니다. 앱·도우미·복사 프로세스의 소유 기록을 확인하므로 실행 중인 작업은 보존하며, 정리 대상은 기록이 있는 캐시와 해당 설치본의 스테이징 폴더입니다. 도우미 초기화가 실패한 경우에도 기존 앱이 종료된 뒤에 재실행합니다.

## 중간에 실패했을 때 복구

먼저 오류 원인을 해결한 뒤, 스크립트가 출력한 복구 명령을 사용합니다. `patch`를 다시 실행하기 전에 버전 커밋과 태그가 이미 생겼는지 확인하세요.

### 버전 커밋 전 실패

권한이나 변경 이력 검사 실패는 버전을 변경하기 전에 중단됩니다. 빌드나 패키징이 실패하면 스크립트는 `Info.plist`를 원래 상태로 복원합니다. 원인을 해결한 뒤 같은 릴리스 명령을 다시 실행합니다.

### 버전 커밋 후 실패

로컬 버전 커밋과 생성된 배포 파일을 유지하며, 다음 실행은 이미 올라간 버전이나 태그 때문에 중단될 수 있습니다. 기존 결과물로 배포를 마무리합니다.

아래는 `1.5.5`에 대한 예입니다. 실제 복구에는 스크립트가 출력한 버전과 경로를 사용하세요.

태그 생성 단계에서 실패해 태그가 없는 경우에만 태그를 만듭니다.

```bash
git tag -a v1.5.5 -m 'VJDeck v1.5.5'
```

푸시 단계에서 실패했다면 권한이나 네트워크 문제를 해결하고 다시 푸시합니다.

```bash
git push --atomic origin main v1.5.5
```

공개 릴리스가 아직 없는 저장소에는 준비된 파일로 릴리스를 만듭니다. 스크립트는 저장소마다 필요한 명령을 출력하며, 아래 예는 `vjdeck/app`과 `vjdeck/site` 두 곳 모두 없는 경우입니다.

```bash
for repo in vjdeck/app vjdeck/site; do
  gh release create v1.5.5 \
    build/release/VJDeck.dmg build/release/VJDeck-1.5.5.zip \
    -R "$repo" --title v1.5.5 \
    --notes-file build/release/notes-1.5.5.md
done
```

릴리스는 생성됐지만 파일 업로드가 덜 끝났다면 첨부 파일과 노트를 다시 올립니다. `--clobber`는 해당 릴리스에서 이름이 같은 첨부 파일을 교체합니다.

```bash
gh release upload v1.5.5 \
  build/release/VJDeck.dmg build/release/VJDeck-1.5.5.zip \
  -R vjdeck/app --clobber
gh release edit v1.5.5 -R vjdeck/app --title v1.5.5 \
  --notes-file build/release/notes-1.5.5.md
```

배포가 완료된 버전은 수정 내용을 더하더라도 같은 번호로 다시 배포하지 않고 새 버전으로 올립니다. 이미 설치한 앱은 같은 버전을 새 업데이트로 판단하지 않습니다.
