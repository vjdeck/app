# VJDeck URL Scheme

외부 앱이나 스크립트에서 VJDeck의 특정 덱에 비디오 또는 이미지 파일을 로드할 수 있습니다.

## Scheme

```
vjdeck://
```

## 사용법

```
vjdeck://load?deck={덱번호}&file={파일경로}
```

| 파라미터 | 필수 | 설명 |
|---------|------|------|
| `deck` | O | 덱 번호 (1~4) |
| `file` | O | 비디오 또는 이미지 파일 절대 경로 |

## 예시

```bash
# 덱 1에 비디오 로드
open "vjdeck://load?deck=1&file=/Users/bada/Videos/my_video.mp4"

# 덱 2에 MKV 파일 로드
open "vjdeck://load?deck=2&file=/path/to/video.mkv"

# 정지 이미지도 동일하게 로드
open "vjdeck://load?deck=2&file=/path/to/image.png"
```

## 무시되는 경우

아래 조건에 해당하면 아무 동작 없이 무시됩니다:

- 해당 덱 번호가 활성화되지 않은 경우
- 파일이 존재하지 않는 경우
- `deck` 또는 `file` 파라미터가 누락된 경우
