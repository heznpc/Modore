# Work resource control

The owner's unit is a working environment: an existing simulator, project/session,
and an external SSD with its actual users. Modore owns the inventory, resource
leases, actions and receipts. Taxi is not required.

## Entry points

- 작업 → 작업 환경 보기, or Command-Shift-K while in 작업.
- `modore resources status`: live devices, runtime IDs, duplicate groups, external
  volume UUIDs, open-file users, registered sessions, and stale connections.
- MCP `work_resource_status` exposes that inventory to sessions.
- `modore resources acquire --runtime <ID> --project <path> --session <ID>` selects
  an existing available simulator. It never creates a device. The preferred
  shared device wins within the requested OS/type, otherwise a booted one wins.
- `claim --id <UDID-or-volume-UUID> --project <path> --session <ID>` records use.
- `bind --id <ID> --fingerprint <fingerprint> --provider <provider> --project <path>
  --session <raw-provider-session-ID>` saves the same persistent assignment as
  the app's project connection. `unbind` removes it. Releasing or expiring a
  usage lease does not erase that setting.
- `heartbeat --session <ID>` renews for fifteen minutes; `release` expires it.

The ops skill tells subsequent sessions to discover/reuse/register before
starting simulator work and to specify the returned UDID in every tool action.
Trusted PreToolUse hooks enforce registration on supported shell and MCP device
calls. Names and historic session
workspace metadata do not prove ownership of a currently running simulator.
The UI opens on active resources: a compact summary, device cards, and a project
sidebar. Idle simulators are collapsed. Registered project/session connections
and observed process usage are distinguished; process lists, paths, identifiers,
and expired registrations live in a separate detail sheet. Connecting a project
opens a searchable recent-session picker. Active-lease warnings are confirmed at the affected action, not with
a global override checkbox.

## Actions

The UI offers boot, shutdown, preferred-device selection, explicit duplicate
device deletion, and normal SSD ejection. Ejection uses diskutil; if a DB/VM/server
still holds the SSD, the failure and observed blockers remain visible. No generic
force-kill or force-eject substitutes for an application's normal shutdown.

Mutations compare a fresh device/volume fingerprint with the reviewed target and
serialize with registration under a Modore-local file lock. Active leases are an
overridable warning. Duplicate deletion requires a shutdown device, another
identical runtime/type device, and no device pairing. Different OS versions are
never duplicates. Device deletion is permanent and the UI says so explicitly.
Each mutation persists its attempt first, then its command result, independent
postcondition verification, and actual free-space readings. Receipts are under
Application Support/Modore/work-resources.

## Existing-feature audit rule

Hook registration and hook execution are separate states. `resources status`
returns `hookStatus` for Codex and Claude: configuration presence, disabled
state, and the latest lifecycle invocation received. Only a receipt within
15 minutes and after the configuration's last change is marked recent. Older
registrations without receipts stay unverified; they are not inferred from
transcripts or resource leases. Codex hook trust is controlled by Codex, not
granted by Modore. This status does not certify that every session or tool call
is protected by the separate CLI guard.

The native work-environment screen shows these states. It queries when opened,
on explicit refresh, and after an action, instead of spawning an inventory
process every ten seconds while the page is visible.

## Saved settings and hook enforcement

Selection is shared by acquire, begin-test and the tool guard: the session's
saved binding, its existing lease, the project's binding, then the shared
preference. A missing, changed or occupied saved target produces an error,
never a silent replacement. The picker stores the provider session ID rather
than its prefixed display-row ID; legacy lease IDs are normalized on read.

`resources diagnose-hooks --project <path>` asks the installed Codex app-server
for `hooks/list`. The app exposes the same diagnosis. Enabled configuration,
trust and observed execution are separate. Untrusted hooks cannot produce a
healthy status, even if an old invocation receipt exists. Modore never writes
trusted hashes. Review the four Modore hooks in Codex `/hooks`: prompt context,
managed test shutdown, resource guard and deployment-CLI reuse guard.

The resource guard matches all tools, blocks physical-device commands and MCP
operations, and checks explicit simulator IDs against saved assignments and
foreign leases. Literal shell wrappers and small local interpreter scripts are
inspected without execution. This is bounded inspection, not an OS sandbox:
arbitrary dynamic/encoded code, unrelated app automation, and hosts that do not
invoke PreToolUse are outside enforcement. Do not represent global bypass
prevention or the current desktop chat as verified from CLI evidence alone.

`python3 tests/run_codex_resource_probe.py <new-output-directory>` runs the
installed Codex executor against a local Responses fixture and fake shell/MCP
devices. It records injected app settings, accepted calls and rejected calls.
Its one-invocation trust bypass applies only to its vetted temporary CODEX_HOME;
it never changes the user's trust, invokes a real device command or contacts an
AI service. Normal account hook execution still requires the user's approval.

Before claiming a capability is missing, follow its existing collector, stored
result, UI and executor. Full storage collection already exists in
scripts/modules/macos/storage.sh; a bounded storage-watch status is not a
substitute for that full inventory. Existing simulator inventory and keep rules
remain separate from live resource/session registration. This change adds the
missing connection and control surface rather than replacing the storage scan.

## Storage and lifecycle retirement

The resource cards now link to [환경 정리](ENVIRONMENT_RETIREMENT.md). This adds
explicit nonduplicate device/runtime retirement, separate iOS/iPadOS/watchOS
requirements, project-server and VM shutdown, ordered SSD ejection, app restart,
exact-type device reuse/setup, quiet cache scheduling, and delayed remeasurement.
The older duplicate shortcut remains scoped to duplicates; it is not the only
route for a user to approve device deletion. `modore environments status` and MCP
`environment_retirement_status` expose the new inventory and requirements.

## Browser test turns

Playwright CLI sessions can outlive the agent's response and leave separate
Chrome instances in the Dock. Simulator-only lifecycle registration did not
cover them. `resources begin-browser-test` now creates one isolated Chromium
execution per observed turn, using an installed CLI, a unique name and a private
workspace. It returns the working directory and argv for subsequent browser
actions. Repeated calls reuse the same browser; they do not create more windows.

The existing synchronous Stop hook closes only that registered execution after
checking its process start identity and session-file fingerprint. `hold` retains
a requested preview, and `release` closes it. There is no AI-session stop, generic
process kill, or workspace deletion. Normal browser close discards transient
test cookies and page state. Uncertain launches, failed closes, and missing hooks
remain visible in the registry and receipts. Other browsers are not adopted.
`resources status` exposes these runs in `browsers`; native resource cards remain
limited to simulators and volumes. The hook and ops skill guide new test turns
through the managed launch command; bypassing it is still outside this coverage.

## Mac 앱과 CLI의 공통 실행 경로

앱의 자원 조회·프로젝트 연결·사용 등록·기본 기기 지정·기기 시작/종료·외장 볼륨 추출·Codex 훅 진단은 Swift 구현을 사용합니다. Mac CLI의 해당 명령도 같은 앱 실행 파일을 호출합니다. 파일 목록·상태·plist·사용 기록·영수증을 Swift에서 처리하며 simctl·diskutil·lsof·app-server는 필요한 로컬 전송 수단으로 사용합니다. 모든 simctl 조작은 UDID를 명시합니다. 시뮬레이터 기기는 보존하며 삭제 명령은 제공하지 않습니다.

수명주기 훅의 턴/브라우저 테스트 관리와 훅 설정은 소스 Python 도구에 남아 있으며 같은 leases.json과 lock을 공유합니다. TTL 만료만으로 다른 세션의 작업 종료를 확정하지 않습니다.
