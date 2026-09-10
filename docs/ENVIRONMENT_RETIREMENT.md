# Environment retirement in Modore

## User flow

Storage opens with **전체**: physical APFS capacity, Data/System/Preboot/Recovery/VM
breakdown, then disjoint Data directories. Mounted simulator images and external
drives are not counted again. The existing deep scan and cleanup catalog remain
available in their tabs. Denied traversal reports a lower bound; timeouts report
unknown. Cached measurements show their timestamp and can be refreshed.

**시뮬레이터·실행 환경 정리** (also available from 작업 환경) opens a measured
review. No device is silently selected for deletion. Separate tabs cover:

- Device data: real allocated directory size and permanent-data-loss warning.
- OS runtimes: installed image size, affected devices, redownload warning.
- Regenerable dyld caches: one aggregate size; per-runtime sizes are unknown rather
  than duplicated. Removing these does not erase simulator apps or login data.
- Project servers: user-owned known server executables, observed working directory,
  exact PID/start-time/command identity; sends SIGTERM, never SIGKILL.
- Lima/Colima VMs: observed hostagent matched against `limactl list`; uses normal
  `limactl stop` with the verified instance and LIMA_HOME, preserving VM disks.
- External drives: volume UUID/device/mount identity; normal `diskutil eject` runs
  after selected servers and VMs. Unresolved users can still cause a normal eject
  failure; no forced ejection fallback.

The iOS, iPadOS, and watchOS requirements default on independently. Users can edit
these and add project-specific OS versions. Requirements and existing keep marks
are warnings, not a veto. The review explicitly warns when a selected deletion
leaves no device, or removes the runtime under a retained platform. Running-device
deletion includes normal shutdown in the explicitly approved action. Missing
identity, unsupported runtime state, and mismatched fingerprints cannot be
waived by acknowledging a warning.

**필요한 OS·기종 준비** lets the user choose an installed OS and an exact compatible
model. The executor reuses an existing exact OS/type; it only creates if absent,
under the Modore transaction lock. Missing iOS/iPadOS or watchOS versions can be
downloaded explicitly with Xcode's platform installer. Download success and
available-runtime verification are distinct. Old simulator user data is not restored.

**앱 재시작** requests normal AppKit termination and opens the same verified bundle.
A changed PID/start date or replaced bundle requires a new selection. If the app
needs a save decision, the operation stops waiting after 30 seconds; no force quit
or duplicate relaunch occurs. Before/after memory and capacity go in its receipt.

## Approval, retry, cancellation, receipts

`environment_retirement.py` is a Modore domain executor. It is embedded and signed
with the app and invoked with pinned script/request descriptors. No Taxi execution,
audit, database, or approval authority is used.

Each plan persists the exact inventory. Approval applies to selected identifiers.
Immediately before each mutation the executor observes the target again. A changed
fingerprint revokes only that item's approval; **이 항목 다시 확인** refreshes only
that item. Unchanged failed items retain approval and can be retried. Successful
mutations are never repeated to obtain verification. An interrupted attempted
removal that is now absent is reconciled as complete. Cancelling stops later items;
an explicit retry resumes the approved remainder.

Receipts persist attempting/succeeded/failed separately from verified/pending.
Capacity is remeasured separately, including a delayed read after execution and a
manual remeasure button. APFS background deletion is not considered settled merely
because simctl returned zero. Net free-space change may include other applications.

Plans, policy, disk balance, app-restart and setup receipts live in
`~/Library/Application Support/Modore/environment-retirement/`.

## Quiet scheduled maintenance

Opt-in scheduling runs while Modore is running, without a wake assertion or
notifications. Users choose specific regenerable runtime caches, an interval, and
a free-space threshold. This grant never covers device data, runtimes, project
servers, VMs, or drives. Each scheduled pass creates a plan and receipt with fresh
identity checks. No-effect passes back off to at least 24 hours, capped at a week;
the next time and prior outcome are visible in the policy section. Closing Modore
pauses this scheduler; it is not a hidden launchd deletion service.

Health notifications only occur on meaningful incident changes, not every ten
minutes. Display sleep, screen lock and an off-console login session suppress
both foreground health notices and the background storage-notice delivery path.
Observation and local receipts continue without forcing the screen awake.

## Session discovery

`modore environments status [--project /absolute/project]` and the read-only MCP
`environment_retirement_status` expose platform requirements, missing platforms,
runtimes, VMs and physical disk capacity. Use existing `work_resource_status` for
live simulator/session leases and SSD open-file users. These surfaces do not infer
ownership from a device name or the last-used device, and do not expose destructive
execution as a read-only MCP tool.

Repository archiving/local retirement remains in the existing asset-retirement
transaction: ignored data is preserved by default, generated ignored outputs have
separate size/selection, warnings are overridable, identity checks are not, and
partial retries retain unchanged approvals. Its existing regression tests are run
alongside environment retirement tests.

## Local macOS access

A CLI running under a terminal can have access that the installed app does not.
VMs whose hostagent is observed but whose instance directory cannot be read remain
visible with an unverified state. **폴더 접근 허용** uses the native folder picker
and retains only the explicitly selected folder's security-scoped bookmark. It
does not edit TCC databases or silently turn on Full Disk Access. Revalidation and
normal VM stop require the instance to become readable; the displayed hostagent
alone does not authorize an arbitrary termination command.

The health landing page links directly to full storage, environment recovery and
app restart. PID/path details, session lists and historical incident logs are
collapsed by default, so a warning leads to a concrete action rather than another
unbounded log page.
