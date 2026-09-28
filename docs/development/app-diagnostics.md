# Native app reproduction diagnostics

Start at **무엇을 해결할까요? → 앱이 버벅여요**, or choose **앱 버벅임 진단**
in the visible sidebar. The same main window guides app selection, recording,
and results. Select a running app, optionally label the condition, then start.
Advanced replay registration, previous comparisons and collector details are
collapsed until needed. Page/stage changes use a 160ms opacity transition and
respect Reduce Motion. A nonactivating floating controller provides markers,
3-second stack capture, and stop/save. High CPU also triggers bounded automatic
stack capture, disclosed before starting. No TTS or timed instruction stages run.
The five-minute collection limit is shown before starting.
Starting activates the selected target app; explicit user stop returns to the
Modore window that started the recording. Automatic timeout never steals focus.

## Architecture and limits

- `NativeCPUReader` is shared by the existing health observer and this feature.
  It converts Mach CPU ticks with the host timebase and rejects PID reuse and
  long observation gaps. An OS `getrusage` regression test checks real units.
- `AppDiagnosticRecorder` is an actor. Native libproc calls are serialized;
  no Python, shell, `ps`, or recurring external process powers this recording.
  The process tree is refreshed every four seconds; at most 64 target processes
  are included. Truncation/missing measurements are explicit.
- Samples begin at a 0.5-second interval, back off with measured collection cost
  and thermal state, and stop at 300 seconds / 600 frames. Events cap at 300.
  The existing CPU observer pauses and invalidates continuity during a run.
- The only child tool is `/usr/bin/sample`: a renderer at >=150% or aggregate
  target CPU at >=200% triggers up to two automatic attempts. A busy renderer
  is preferred; otherwise the hottest target process is sampled. Manual and
  automatic captures share a three-capture limit, 30-second cooldown, 3-second
  duration and watchdog. Failed automatic attempts also consume the two-attempt
  budget; serious/critical thermal states suppress automatic capture.
  Stop/quit terminates owned sampling and preserves partial results.
- CPU totals sum concurrent target descendants, then use elapsed-time weighting.
  Renderer CPU (name-based) and the top eight processes at each frame are retained
  separately so worker/tool descendants cannot be mistaken for UI-only CPU.
  Modore's own CPU and sampler CPU are separate. RSS can double-count shared pages.
- Frames and events stream to private local files. Normal finish writes a bounded
  `result.json` and `report.md`. Abrupt process death leaves partial JSONL data;
  incomplete runs are not presented as complete history entries.
- Results persist under `~/Library/Application Support/Modore/AppDiagnostics/`.
  Only the newest 20 result files are loaded (each capped at 4 MB); nothing is
  automatically deleted. Private native stacks may contain paths.

## Result interpretation

Schema 3 reports analyze existing recordings as well as new ones. Each manual or
automatic-start marker gets a three-second before/after window. Only samples
entirely inside a window are included; at least 75% duration coverage and no
unavailable processes are required to call a comparison complete. An observed
peak >=150% is reported even with missing baseline data, but a rise requires a
complete baseline/response, a peak >=2x baseline and >=75 percentage points above
baseline, and no overlapping action or stack capture. These are evidence triage
thresholds, not a claim of abnormality or causation. Renderer values are used
when available; legacy aggregate-only recordings explicitly lack attribution.

The history page caches presentation analysis at load/save time, avoiding a
full history rescan on every live 0.5-second update. No fixed "cause unknown"
status replaces recorded findings. Low CPU is never interpreted as absence of
UI latency. System memory pressure, disk wait and display latency are not
measured by this recorder. Stack capture can perturb the observed interval and
is marked accordingly; a stack is evidence for inspection, not an automatic
root-cause determination.

## Automatic replay

Grant Modore macOS Accessibility access explicitly. Register an empty ordinary
text field and a hover destination by clicking each in the target app. Registration
expires after a minute and is cancelled when leaving the page. No app-wide
accessibility tree crawl or keystroke-content collection runs.

During recording, **등록 동작 재현** performs 1–3 repetitions: focus/click the
registered field, type a fixed test string, move the pointer to the registered
hover element, then remove exactly its own unchanged string through Accessibility.
It never sends Return or clicks a send button. Esc and the controller cancel.
PID identity, frontmost app, hit-test element, focus and text contents are checked
between actions; external edits or target changes stop the sequence. If removal
cannot be confirmed, inspect the target draft. Some apps expose no usable AX field
and can only use manual recording. Image attachment is a manual marker, not an
automated attachment test. Unicode injection is not an IME-composition test.

The recorder does not measure input-to-display latency. `auto-verified` means the
AX value matched the fixed string, not that a frame rendered on time. Comparisons
flag mismatched/incomplete action sequences and stack-collection settings and do
not declare a performance fix based on CPU reduction alone.

## Validation

`swift test --package-path macos/Modore -j 2 --filter 'AppDiagnosticTests|CPUWatchTests|HealthContextTests'`

`Tests/Fixtures/DiagnosticFixture.swift` is a separate offline AppKit fixture for
end-to-end field registration and replay. Compile it as an app with an explicit
macOS 13 deployment target and launch through Launch Services. This is not part
of the shipping executable. Test ordinary completion, Esc cancellation, nonempty
field refusal, target changes, and persistence after Modore relaunch.

## Local validation record (2026-09-28)

- Strict-concurrency release build and signed bundle verification passed.
- Installed app launch and toolbar entry verified through native UI tooling.
- User completed a 125-frame ChatGPT run and exported its report from Modore.
- Guided UI follow-up: installed signed app verified with native UI tooling.
  Start goal to embedded diagnostic, Mac status to Start navigation, and a
  separately labeled Calculator fixture's start/marker/stop/result flow passed
  (15 frames, about 7.5 seconds). Preparation/result pages showed no clipping.
  The floating controller's own layout was not separately inspected. No ChatGPT
  reproduction or latency improvement is claimed from this UI check.
- Follow-up analysis/spike changes: 19 focused diagnostic/CPU tests passed.
  A separate bounded native load fixture reached about 295% CPU; the production
  recorder automatically saved one nonempty native stack, persisted schema 3
  results, and respected the cooldown. Existing schema 1 data was reanalyzed
  with the same production model without another user reproduction.
- Automated replay end-to-end validation remains pending: the native UI tool
  disconnected while opening the diagnostic window (`native pipe closed before
  response`). No successful keyboard/hover replay is claimed from that run.
