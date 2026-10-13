# macOS 빌드 산출물 보관

`scripts/build_macos_swift_app.sh`는 기본 출력 `build/macos/Modore.app`을 재사용합니다.
`scripts/test_macos_swift_app.sh`는 `build/verification/swift-verification` 한 곳에서
Swift 테스트를 실행합니다. 실패한 검증 폴더가 남아 있으면 덮어쓰지 않습니다.
`scripts/test_macos_swift_app.sh --retry-failed`는 이전 실패 폴더와 기록을
`build/verification/failed/<기록-ID>`에 보존한 뒤 고정 검증 경로에서 재시도합니다.

실행별 생성 경로, 시작·검증 종료 시각, 프로세스 식별, 검증 결과, 파일 내용과
식별 정보는 `~/Library/Application Support/Modore/build-artifacts`에 저장됩니다.
성공 종료 뒤 회수 조건을 다시 확인하며 저장소별 최신 최종 앱과 복구본을 각각
1개 보관합니다. 실패·중단·사용 중·검증 후 변경·사용자 증거가 있는 산출물은
이 한도와 관계없이 보존합니다. 기록 없는 과거 폴더도 자동 삭제하지 않습니다.
기존 `PCH_KEEP_PREVIOUS_APP` 옵션 대신 이 보관 정책을 적용합니다.

Python 다운로드는 `~/Library/Caches/Modore/build-runtime/python`에 공유합니다.
기존 출력 폴더의 캐시는 서명된 앱의 `ORIGIN.txt`와 SHA256이 일치하면 먼저
재사용합니다. 복사본 회수 시 공용 원본과 다시 비교하고, 현재 빌드가 사용하는
캐시는 유지합니다. 출력 폴더 이름을 바꾸어도 같은 런타임을 다시 다운로드하지 않습니다.

앱의 **저장공간 → 환경·프로젝트 검토 → 빌드 산출물 보관·회수**에서 생성·검증
기록과 보존 사유를 확인할 수 있습니다. **설치본 연결 확인**은 설치 앱의 서명과
빌드 서명이 일치할 때만 연결합니다. 검토 전용 모드에서는 회수 버튼이 비활성화됩니다.

명령줄에서도 같은 기록을 사용합니다.

```sh
python3 scripts/build_lifecycle.py report
python3 scripts/build_lifecycle.py link --id <빌드-기록-ID> --path "$HOME/Applications/Modore.app"
python3 scripts/build_lifecycle.py reclaim
```

`reclaim`은 사용자 프로젝트·다운로드·세션 전체를 조사하거나 삭제하는 명령이
아닙니다. 관리 빌드가 기록한 산출물만 검증하며, 현재 사용 여부를 확인하지 못하면
회수하지 않습니다. Swift 컴파일 산출물의 회수와 사용자 정리 후보의 삭제 기록은
서로 다른 기록으로 유지합니다.
