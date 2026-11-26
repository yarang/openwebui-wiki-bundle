# HOP 뷰어 키트 (오프라인 HWP/HWPX 뷰어 · macOS arm64)

인터넷 없는 현장 Mac 에 한글 문서(.hwp/.hwpx) 뷰어 [HOP](https://github.com/golbin/hop)을
얹는 소형 꾸러미입니다. HOP은 MIT 라이선스입니다(내장 엔진 rhwp-core도 MIT).
이 꾸러미는 문서를 열어 보는 용도로 넣습니다.

> 통합 번들에도 이 폴더가 `hop-viewer/` 로 들어 있고, `install-all.sh` 7/7 단계가
> 자동으로 돌립니다(`--no-hop` 으로 생략, `--no-hop-register` 면 기본 앱 등록 생략,
> `--hop-app-dir=DIR` 로 앱 위치). 앱 위치를 주지 않으면 `/Applications`, 쓸 수 없으면
> `~/Applications` 에 둡니다. 쓸 수 없는 `/Applications` 에 HOP 이 이미 있으면 단계를
> 건너뜁니다. 이 꾸러미를 따로 옮기는 것은 이미 설치된 Mac 에 더하거나 새 버전으로
> 바꿀 때입니다.

## 꾸러미 구성

| 파일 | 내용 |
|---|---|
| `app/HOP-macos-arm64.dmg` | HOP.app (Developer ID 서명 + 공증·스테이플; 봉인은 인스톨러가 재검증) |
| `install-hop.sh` | 설치 스크립트 |
| `README.md` | 이 문서 |
| `MANIFEST.env` | 버전·번들 ID·서명 팀·출처·라이선스 |
| `SHA256SUMS` | 위 파일들의 sha256 (설치 전 무결성 확인에 쓰임) |

## 설치

```bash
shasum -a 256 -c SHA256SUMS   # 먼저 무결성 확인
./install-hop.sh --dry-run    # 할 일 미리보기
./install-hop.sh              # 설치 (기본 /Applications)
```

| 옵션 | 동작 |
|---|---|
| `--dry-run` | 모든 행동을 출력만 하고 변경 없음 |
| `--app-dir=DIR` | 앱 설치 위치 (기본 `/Applications`) |
| `--no-register` | LaunchServices 등록 건너뛰기 |

인스톨러는 dmg 안의 앱이 매니페스트와 같은 버전·번들 ID 인지, 봉인이 유효하고 핀된
팀(CNP6UV7S33)의 서명인지 확인한 뒤 `ditto` 로 복사하고 그 앱에만
`com.apple.quarantine` 을 지웁니다. sudo 는 쓰지 않습니다. 이미 같거나 더 새 HOP이
있으면 그대로 두고, 이전 버전은 `HOP.old-<버전>.app` 으로 옮겨 둡니다(삭제하지 않음).
같은 자리에 번들 ID 가 다르거나 버전을 읽을 수 없는 HOP.app 이 있으면 그것도
`HOP.old-<버전|unknown>.app` 으로 옮겨 둡니다.

## 쓰는 법

- .hwp/.hwpx 파일을 두 번 클릭해 HOP으로 열기 (`open -a HOP 문서.hwp` 도 됩니다)
- Finder 에서 파일을 고르고 스페이스바 → Quick Look 미리보기, 폴더의 썸네일도 HOP이
  그립니다 (`Contents/PlugIns/HopQuickLookPreview.appex`, `HopQuickLookThumbnail.appex` 포함)

## 알아둘 점

- HOP은 .hwp/.hwpx 를 LSHandlerRank Owner 로 등록하므로 설치 뒤 이 확장자의 기본 앱이
  HOP으로 바뀔 수 있습니다. 되돌리려면: Finder 에서 .hwp 파일 하나 선택 → 정보 가져오기
  (Cmd+I) → "다음으로 열기" 에서 원래 앱 선택 → "모두 변경"
- HOP은 시작할 때 업데이트를 한 번 확인합니다(github.com/golbin/hop/releases). 오프라인
  이면 로그만 남기고 조용히 실패하며, 업데이트는 사람이 직접 눌러야만 설치됩니다. 그 외
  네트워크 통신은 없습니다.
- dmg 파일 자체는 공증(notarize)되지 않았지만 안의 HOP.app 은 공증 + 스테이플 됐습니다.
  설치 스크립트가 서명과 팀을 확인한 뒤 앱의 quarantine 만 지웁니다.
- rhwp 등 변환기로 만든 hwpx 는 문서 안의 미리보기 그림이 비어 있어 Finder 썸네일이
  흰 화면일 수 있습니다 — 파일을 열면 내용은 정상입니다.
- 인텔 Mac, macOS 12 미만에서는 설치되지 않습니다 (arm64 전용, LSMinimumSystemVersion 12.0).

## 되돌리기

1. 등록 해제:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "/Applications/HOP.app"`
2. `/Applications` 에서 `HOP.app` (과 `HOP.old-*.app`) 을 휴지통으로
3. 기본 앱이 바뀌었다면 위 "모두 변경" 으로 원래 앱으로 되돌리기

## 꾸러미 만들기 (빌드 Mac)

- 벤더 파일: `dist/vendor/hop/HOP-macos-arm64.dmg` (gitignore 됨)
- `guardian/pack-hop-viewer.sh` 실행 → `dist/hop-viewer/hop-viewer-<버전>/` 폴더와
  `.tar.gz` + `.tar.gz.sha256` 이 만들어진다. 스크립트가 벤더 dmg 의 sha256·버전·번들
  ID·서명 봉인·팀, 그리고 앱의 공증 스테이플(없으면 중단)을 확인한다.
- 새 버전으로 옮기려면: 새 dmg 를 벤더 위치에 두고 pack 스크립트 상단의 핀 네 값
  (버전·sha256·번들 ID·팀)을 고친 뒤 `guardian/tests/accept_hop_viewer.sh` 를 돌린다.
