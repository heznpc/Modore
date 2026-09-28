# LagQA

ChatGPT 데스크톱의 첫 입력·목록 hover·사진 첨부 지연을 구간별로 기록하는 독립 macOS QA 앱입니다. SwiftPM + AppKit/SwiftUI로 동작합니다.

```sh
./script/build_and_run.sh --verify
swift test -j 2
```

빌드 스크립트는 `~/Applications/LagQA.app`에 설치합니다. 측정 시작을 누른 뒤 ChatGPT를 평소처럼 사용하고, 끝나면 측정 종료를 누릅니다. 음성·카운트다운·자동 단계 전환은 없습니다. 종료 후 동작별 체감을 선택하면 함께 저장합니다. 같은 사진·첨부 방법으로 긴 대화와 짧은 대화를 각각 측정할 수 있습니다. 측정 시작 전 원하는 대화를 직접 열어두세요.

결과: `~/Library/Application Support/Heznpc/LagQA/Runs/<run-id>/`

- `cpu.csv`: libproc 누적 Mach tick을 시스템 timebase로 나노초 변환한 뒤 차이로 계산한 약 1초 평균, RSS, 접근 실패 표시. PID 재사용을 검사합니다.
- `timeline.json`: 실제 관찰 구간 시작·종료의 UTC 시각. 조작 이벤트를 뜻하지 않습니다.
- `markers.json`: 실행 이후 추가된 앱 로그의 고정 오류 표식과 시각만 저장합니다.
- `native-private/`: 20초마다 짧게 수집한 메인 프로세스와 가장 큰 renderer의 macOS `sample` 결과. 원본에는 환경 경로가 포함될 수 있습니다.
- `user-observations.json`: 사용자 체감 및 대화 조건.
- `report.md`, `manifest.json`: 요약과 수집 제한.

ChatGPT UI를 자동 조작하거나 화면·키 입력·사진 내용·대화 내용을 수집하지 않습니다. 화면 기록/접근성 권한은 요구하지 않습니다. CPU 평균은 입력 지연이나 프레임 시간을 직접 측정하지 않습니다. 조작 종류나 정확한 입력 시점을 자동 감지하지 않으며 native sample은 JavaScript 심볼을 완전히 제공하지 않습니다. 외부 공유 전 원본 스택을 검토해야 합니다.

`--smoke-test`는 12초간 자동으로 실행해 수집·저장 경로를 검증합니다. 사용자 재현 결과와 분리해 `smoke-` 폴더에 저장합니다. 측정 중 창을 닫거나 종료하면 부분 결과를 저장하고 소유한 sampler를 중단합니다. 상시 실행이나 자동 시작은 등록하지 않습니다.

1.1에서 CPU 시간 단위 및 집계를 수정했습니다. 1.0은 ARM의 Mach tick을 나노초로 오인해 CPU를 축소 표시했고, 여러 renderer의 개별 평균이 부하를 희석했습니다. 새 요약은 같은 시점의 같은 역할 PID를 합산하며 manifest에 변환 계수를 저장합니다.
