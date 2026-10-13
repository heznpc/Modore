# 생성 캐시 정리 규칙

일반 검사와 전체 디스크 조사는 경로를 **검증 대상**으로만 제시합니다. 선택 후 `cleanup.sh`의 기존 `project_residue` 승인 흐름에서 `generated_cache.py`를 실행합니다. 앱은 두 실행 파일과 Python 런타임을 서명된 번들에서 고정합니다.

| 대상 | 필요한 근거 |
| --- | --- |
| `.next` | Next.js package.json, 잠금 파일, 생성 매니페스트 |
| `.venv` | pyvenv.cfg, 고정 복원 명세, 설치 RECORD 해시, 미등록·로컬·편집 가능 패키지 부재 |
| Xcode 출력 | info.plist의 실제 원본 프로젝트, 지정된 Build·noindex 하위 경로 |
| XcodeBuildMCP test-products | xctestrun, 연결된 DerivedData의 원본 프로젝트 |
| Dart 분석 캐시 | 설치 SDK, ByteStore 파일명·버전·체크섬 |
| node-gyp / Electron | 버전 일치 Node 헤더 / Electron macOS 아카이브 식별 |
| VS Code 다운로드 / 구 확장 | 서명된 설치 앱과 VSIX 형식 / `.obsolete` 및 현재 등록된 후속 버전 |
| GoogleUpdater crx_cache | 서명된 업데이터, 번들 식별자, CRX3 헤더와 ZIP 본문 |
| Flutter engine | SDK 소스, engine.version, 정확한 엔진 산출물 하위 경로 |

대상 전체의 소유권·외부 링크·특수 파일·보존 증거를 검사합니다. `.xcresult`, 로그, 영상, 첨부 자료, 세션 기록 등이 섞이면 해당 폴더를 보존합니다. Xcode의 Logs·TestResults는 형제 경로로 남으며 DerivedData 루트 전체는 정리 대상이 아닙니다.

열린 파일 조사 실패·시간 초과·관련 도구 실행은 삭제를 차단합니다. 승인에는 원본 명세 해시, 대상 파일 식별·변경 시각, Git 추적 상태가 포함되어 실행 직전 변경되면 취소됩니다. 검증 25초·150,000개 파일 상한을 넘거나 형식이 다르면 보존 이유를 반환합니다. 실제 재생성 실행 여부는 별도로 **미검증**으로 표시합니다.

Dart의 지원 형식은 공식 [FileByteStoreValidator](https://github.com/dart-lang/sdk/blob/main/pkg/analyzer/lib/src/dart/analysis/file_byte_store.dart)의 v1 버전·Fletcher-16 구조입니다. 다른 형식이나 단일 DB는 보존합니다.
