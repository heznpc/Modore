# Mothball — Git-aware Project Archiver

**버전**: v0.1 MVP 스펙 (2026-04-23 고정)
**플랫폼**: macOS 13 Ventura 이상 (Apple Silicon + Intel universal)
**라이선스 예정**: MIT

---

## 1. 한 줄 정의

오래 안 건드린 git 프로젝트를 안전하게 압축 보관하고 원본을 지워 디스크를 되찾는 macOS 앱.

> "Mothball your old repos." — 영어권 "mothball" 관용구(프로젝트를 휴면 상태로 보관)를 제품명과 카피로 그대로 사용.

---

## 2. 포지셔닝

**이것이다**: 프로젝트 단위 아카이버. git 메타데이터 인지. 압축 후 원본 제거.
**이것이 아니다**:
- ❌ 일반 캐시 청소기 (ClearDisk/Mole 영역 — 안 건드림)
- ❌ 디스크 시각화 도구 (DaisyDisk 영역)
- ❌ node_modules 단독 삭제 도구 (kondo/npkill 영역)
- ❌ 실시간 디스크 모니터 (v1.0까지 안 함)

### 경쟁 포지션

2026-04 시점, git 메타데이터를 인지하는 프로젝트 아카이버는 **존재하지 않음**. 기존 도구들:
- ClearDisk Projects 탭: stale `node_modules`/`target` 삭제만. git 무시. Apple Silicon 전용.
- Mole `mo purge`: 동일. mtime만 사용.
- kondo/npkill: node_modules 전용.

**차별점 3개**:
1. git 메타 (unpushed commit, dirty working tree, last commit date) 인지
2. 프로젝트 폴더 전체를 `.tar.zst`로 압축 후 원본 제거 (단순 삭제 아님)
3. Intel Mac 지원 (ClearDisk 약점)

---

## 3. 타겟

git 프로젝트 10개 이상을 로컬에 보관하고, 수개월~수년 안 건드린 repo가 누적된 개발자.

---

## 4. v0.1 기능 스펙

### 4.1 스캔

**입력**: 사용자가 `NSOpenPanel`로 고른 1개 이상의 루트 디렉토리.
- 첫 실행 시 `~/` 하위에서 흔한 dev 디렉토리명 자동 추천 (`Projects`, `IdeaProjects`, `code`, `dev`, `work`, `src`, `github`, `repos`). 사용자가 확인 후 추가.
- **Full Disk Access 요구 안 함.** 사용자가 명시적으로 허용한 경로만 읽음.

**검출 로직**:
- 재귀 탐색, `.git` 디렉토리 있는 폴더를 repo로 인식
- 중첩 git repo는 바깥쪽만 (submodule 대응)
- 심볼릭 링크는 따라가지 않음

**수집 메타 (repo당)**:

| 필드 | 획득 방법 |
|---|---|
| `path` | `URL` |
| `size_bytes` | 파일 재귀 합산 또는 `du -sk` |
| `last_commit_at` | `git log -1 --format=%ct` |
| `last_fs_mtime` | 재귀 `stat` 최대값 |
| `is_dirty` | `git status --porcelain` 비어있는지 |
| `ahead_of_origin` | `git rev-list --count @{u}..HEAD` (tracking 있을 때) |
| `has_remote` | `git remote -v` 출력 존재 여부 |
| `origin_url` | `git config --get remote.origin.url` |
| `current_branch` | `git rev-parse --abbrev-ref HEAD` |
| `head_sha` | `git rev-parse HEAD` |

**실행 방식**: Swift `TaskGroup`으로 repo당 병렬 실행, 동시성 제한 8.

### 4.2 안전 분류

| 티어 | 조건 | 의미 |
|---|---|---|
| 🟢 **아카이브 추천** | 180일+ 커밋 없음 AND clean working tree AND origin에 push 완료 (`ahead_of_origin == 0`) AND has_remote | 언제든 `git clone`으로 복원 가능 |
| 🟡 **주의** | 90-180일 미사용 OR (오래됐지만 unpushed commit 있음) OR (오래됐지만 dirty) | 복원 정보 일부 로컬에만 존재 |
| 🔴 **보관 금지** | 30일 내 활동 OR remote 없음 AND 미추적 변경 다수 | 작업 중이거나 복원 불가능 |

**UI 동작**:
- 기본 선택 = 🟢만
- 🟡은 사용자가 명시적 체크해야 선택됨
- 🔴은 회색 처리, 체크 불가 (도움말 툴팁으로 이유 표시)

### 4.3 아카이브 파이프라인

**형식**: `.tar.zst` (`/usr/bin/tar --zstd -cf`, macOS 13 bsdtar 지원 확인됨).

**repo당 절차** (트랜잭션):
1. 대상 임시 파일 `{archive_dir}/{repo_name}_{YYYY-MM-DD}.tar.zst.tmp` 생성
2. 사이드카 임시 파일 `{repo_name}_{YYYY-MM-DD}.json.tmp` 생성:
   ```json
   {
     "schema_version": 1,
     "archived_at": "2026-04-23T12:00:00Z",
     "archived_by": "Mothball/0.1",
     "original_path": "/Users/x/IdeaProjects/old-thing",
     "size_bytes_before": 10485760000,
     "size_bytes_archive": 1234567890,
     "git": {
       "origin": "git@github.com:me/old-thing.git",
       "branch": "main",
       "head_sha": "abc123...",
       "last_commit_at": "2025-08-15T09:00:00Z",
       "ahead_of_origin": 0,
       "was_dirty": false
     },
     "restore_hint": "git clone git@github.com:me/old-thing.git"
   }
   ```
3. 무결성 검증 (`tar --zstd -tf` 성공 확인)
4. `.tmp` 접미사 제거 (rename) — 이 시점부터 아카이브 유효
5. 원본을 **휴지통으로** 이동 (`FileManager.default.trashItem(at:resultingItemURL:)`)
6. 활동 로그 기록

**중단 내성**: 2번 끝나기 전 크래시 → `.tmp` 파일 남음 → 재시작 시 발견하면 정리 prompt. 5번 전 크래시 → 원본 + 완성된 아카이브 양쪽 존재 → 사용자에게 "이미 아카이브됨, 원본 정리?" 프롬프트.

**중단 가능**: 진행 중 취소 버튼 → 현재 repo는 완료 또는 롤백 후 종료.

### 4.4 Fetch 옵션

origin에 push 완료 여부(`ahead_of_origin == 0`)는 로컬 정보만으로는 최신이 아닐 수 있음.

**기본**: fetch 하지 않음 (로컬 tracking ref 기준).
**옵션**: "아카이브 전 `git fetch` 실행하여 최신 상태 확인" 체크박스 (설정에서). 네트워크 I/O 많을 수 있음.

### 4.5 UI

**단일 윈도우, 3화면**:

#### 화면 0 — 첫 실행
> Mothball은 선택한 폴더만 읽습니다. 아카이브 전 항상 확인을 받고, 원본은 즉시 삭제하지 않고 휴지통으로 보냅니다. 네트워크 접근은 `git fetch` 옵션을 켰을 때만 발생합니다.

`[동의하고 시작]` 버튼 → 스캔 위치 선택 화면.

#### 화면 A — 스캔 결과
- 테이블 컬럼: `체크박스 / 이름 / 크기 / 마지막 커밋 / 상태 배지(🟢🟡🔴) / 경로`
- 기본 정렬: 크기 내림차순
- 상단: `[스캔 위치 추가]` `[다시 스캔]`
- 하단: "선택 N개, 총 X.XX GB 회수" + `[아카이브...]` 버튼

#### 화면 B — 확인 다이얼로그
- 선택 repo 목록 재확인
- 🟡 포함 시 경고 ("N개 repo가 unpushed commit을 가지고 있습니다. 아카이브에는 포함되지만 origin에는 없습니다.")
- 아카이브 저장 위치 표시 + `[변경...]`
- `[취소]` / `[아카이브 실행]`

#### 화면 C — 진행
- repo별 상태 행 (대기 → 압축 중 → 완료/실패)
- 전체 progress bar + 취소 버튼
- 완료 후: "N개 repo 아카이브 완료, X.XX GB 회수. 원본은 휴지통에 있습니다."

### 4.6 설정

- 아카이브 저장 위치 (기본 `~/Archive`, 외장 드라이브/iCloud Drive 허용)
- fetch 옵션 on/off
- 스캔 제외 경로 목록

`UserDefaults`에 저장.

### 4.7 로그

`~/Library/Application Support/Mothball/activity.log`:
```
2026-04-23T12:00:05Z ARCHIVE_START path=/Users/x/IdeaProjects/old-thing size=10485760000
2026-04-23T12:00:47Z ARCHIVE_OK archive=/Users/x/Archive/old-thing_2026-04-23.tar.zst size=1234567890
2026-04-23T12:00:47Z TRASH_OK path=/Users/x/IdeaProjects/old-thing
```

Plain text, append-only. 사용자가 직접 열어볼 수 있음.

---

## 5. 기술 결정 (확정)

| 항목 | 결정 | 비고 |
|---|---|---|
| 언어/UI | Swift + SwiftUI | 네이티브. `Observable` 매크로 사용 (macOS 14 도입, 폴리필 필요) |
| 최소 OS | macOS 13 Ventura | macOS 14 API는 `if #available`로 분기 |
| 아키텍처 | Apple Silicon + Intel universal | ClearDisk 약점 공략 |
| git 호출 | `Process` 서브프로세스, 시스템 `/usr/bin/git` | 사용자 PATH에 git 없으면 오류 안내 |
| 아카이브 | `/usr/bin/tar --zstd` 서브프로세스 | macOS 13 bsdtar 3.5+에서 지원 확인 필요 (없으면 `.tar.gz` fallback) |
| 크기 계산 | 파일 재귀 `attributesOfItem` | `du` 서브프로세스는 대안 |
| DB | **없음** | 각 아카이브가 자급자족 (사이드카 JSON) |
| 권한 | Full Disk Access 불필요 | 사용자 선택 경로만 읽음 |
| 배포 | 오픈소스(MIT) + 직배포 `.dmg` | **notarization 필수** (ClearDisk 약점) |
| 앱스토어 | **안 함** | sandbox 제약으로 임의 경로 archive 불가 |

---

## 6. 모듈 구조 (Swift 파일 설계)

```
Mothball/
├── MothballApp.swift              // @main App, WindowGroup
├── Models/
│   ├── RepoInfo.swift             // 스캔된 repo 데이터 모델
│   ├── SafetyTier.swift           // .safe / .caution / .unsafe enum
│   └── ArchiveManifest.swift      // 사이드카 JSON 모델
├── Scanner/
│   ├── RepoScanner.swift          // 디렉토리 walk + .git 탐지
│   ├── GitInspector.swift         // git 서브프로세스 래퍼
│   └── SizeCalculator.swift       // 파일 크기 재귀 합산
├── Classifier/
│   └── SafetyClassifier.swift     // RepoInfo → SafetyTier 규칙 적용
├── Archiver/
│   ├── TarArchiver.swift          // /usr/bin/tar --zstd 래퍼
│   ├── ManifestWriter.swift       // 사이드카 JSON 생성
│   └── ArchiveOrchestrator.swift  // 트랜잭션 파이프라인
├── Trash/
│   └── TrashMover.swift           // FileManager.trashItem 래퍼
├── UI/
│   ├── FirstRunView.swift         // 화면 0
│   ├── ScanScreen.swift           // 화면 A
│   ├── RepoRowView.swift          // 테이블 row
│   ├── ConfirmDialog.swift        // 화면 B
│   └── ProgressScreen.swift       // 화면 C
├── Storage/
│   ├── AppSettings.swift          // UserDefaults 래퍼
│   └── ActivityLog.swift          // plain text log writer
└── Resources/
    ├── Info.plist
    └── Assets.xcassets
```

**예상 코드량**: 2000-3000 Swift 라인.
**예상 개발 기간**: 사이드 프로젝트 주말 3-4회 — prototype, 정식 릴리스까지 2-3개월.

---

## 7. v0.2+ 백로그 (지금은 무시)

- **복원 기능**: `.tar.zst` + 사이드카 → 원위치 추출 또는 origin URL로 `git clone` 실행
- **아카이브 이력**: 지금까지 아카이브한 repo 목록 브라우저, "지난 1년 총 N GB, M개 repo" 통계
- **외장 드라이브 자동 동기화**: 해당 드라이브 마운트 시 대기 중인 아카이브 이동
- **원격 살아있음 확인**: GitHub API로 origin repo 존재/접근 가능 여부 사전 확인 → dead remote 경고
- **Git LFS 대용량 인지**: LFS 객체 별도 취급
- **시계열 진단**: 아카이브 이력 DB를 기반으로 "이 경로가 최근 X개월간 가장 많이 자랐다" 분석 (ClearDisk 미영역)

---

## 8. 열린 질문 (추후 결정)

- **아카이브 네이밍 충돌**: `old-thing_2026-04-23.tar.zst` 이 같은 날 두 번 실행되면 충돌. `{repo}_{YYYY-MM-DDTHHMMSS}.tar.zst` 로 갈지, 또는 suffix(`_2`) 자동 부여할지.
- **zstd 압축 레벨**: 기본 3 vs 19. 기본 3이 빠르지만 크기 1.5배. 백그라운드 작업이라 19도 용인 가능. 벤치마크 후 결정.
- **대용량 단일 파일 처리**: repo 내 100MB+ 단일 파일(바이너리, 영상)이 있을 때 경고할지. 아카이브 자체는 문제없으나 의도하지 않은 경우가 많음.

---

## 9. 성공 지표 (v0.1)

- GitHub 100★ 이내 도달
- HackerNews Show HN 노출 1회
- 실제 사용자(본인 외) 10명 이상
- 치명 버그 0건 (아카이브 손상, 원본 유실)

---

## 변경 이력

- 2026-04-23: v0.1 MVP 스펙 확정 (이름 Mothball 확정, Intel 지원, 휴지통 정책, fetch 기본 off)
