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
  nonfinite/long observation gaps. Membership keeps the discovered birth time
  until the next tree refresh, so a reused child PID cannot rejoin on the second
  sample unless it is still in the target tree. An OS `getrusage` regression
  test checks real units.
- `AppDiagnosticRecorder` is an actor. Native libproc calls are serialized;
  no Python, shell, `ps`, or recurring external process powers this recording.
  The process tree is refreshed every four seconds; at most 64 target processes
  are included. Truncation/missing measurements are explicit.
- Samples begin at a 0.5-second interval, back off with measured collection cost
  and thermal state, and stop at 300 seconds / 600 frames. Events cap at 300, reserving six
  slots for stack evidence. Rejected or failed manual marker writes are shown
  as failures rather than saved markers.
  The existing CPU observer pauses and invalidates continuity during a run.
- The only child tool is `/usr/bin/sample`: a renderer at >=150% or aggregate
  target CPU at >=200% triggers up to two automatic attempts. A busy renderer
  is preferred; otherwise the hottest target process is sampled. Manual and
  automatic captures share a three-capture limit, 30-second cooldown, 3-second
  duration and watchdog. Failed automatic attempts also consume the two-attempt
  budget; serious/critical thermal states suppress automatic capture.
  Stop/quit terminates owned sampling and preserves partial results. Schema 4
  stack start/terminal events share a capture ID and file name; successful
  completion requires a nonempty file. The terminal event uses actual process
  completion, with the six-second watchdog retained for stalled samplers.
  Older stack events without IDs conservatively retain the six-second window.
- CPU totals sum concurrent target descendants, then use elapsed-time weighting.
  Renderer CPU (name-based) and the top eight processes at each frame are retained
  separately so worker/tool descendants cannot be mistaken for UI-only CPU.
  Modore's own CPU and sampler CPU are separate. The displayed native query time
  includes discovery and counter reads, but excludes JSON/report writing and
  stack launch; Modore CPU includes all in-process work. Partial aggregates are
  explicitly labeled and may underestimate actual load. The first zero-length
  baseline is not a measured CPU interval. RSS can double-count shared pages.
- Frames and events stream to private local files. Normal finish writes a bounded
  `result.json` and `report.md`. Abrupt process death leaves partial JSONL data;
  incomplete runs are not presented as complete history entries.
- Results persist under `~/Library/Application Support/Modore/AppDiagnostics/`.
  Only the newest 20 result files are loaded (each capped at 4 MB); nothing is
  automatically deleted. Private native stacks may contain paths.

## Result interpretation

Schema 4 reports analyze existing recordings as well as new ones. Each manual or
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

The recorder measures neither input-handler duration nor input-to-display
latency. CPU percentages are averages over each collection interval; 100% is
one logical core, not the whole machine. Manual marker timestamps originate
at the button action, before the recorder actor queue. Two markers at the same
time remain overlapping actions. `auto-verified` means the
AX value matched the fixed string, not that a frame rendered on time. Comparisons
flag mismatched/incomplete action sequences and stack-collection settings.
They require verified cleanup for every replay repetition and do not declare a
performance fix based on CPU reduction alone.

## Validation

`swift test --package-path macos/Modore -j 2 --filter 'AppDiagnosticTests|CPUWatchTests'`

`swift test --package-path macos/LagQA -j 2`

The diagnostic tests exercise a bounded child workload against POSIX
`getrusage`, real native stack completion/cancellation, target exit, private
result persistence and history presentation models. Set
`MODORE_DIAGNOSTIC_EVIDENCE` to an existing/private output directory to retain
these fixture results and their reference CPU values. Tests without that
variable remove only their own temporary fixture output.

LagQA calculation version 3 weights concurrent role totals by elapsed time,
invalidates counters after failed reads, rejects gaps over ten seconds and
preserves PID birth identity between discovery passes. Phase changes prime a
new baseline rather than attributing the previous interval to the new phase.
Its CSV retains monotonic elapsed/interval seconds alongside wall-clock labels,
marks unavailable/discontinuous rows, and its report counts missing rows.
LagQA remains a legacy recorder; use the Modore page for the guided workflow.

`Tests/Fixtures/DiagnosticFixture.swift` is a separate offline AppKit fixture for
end-to-end field registration and replay. Compile it as an app with an explicit
macOS 13 deployment target and launch through Launch Services. This is not part
of the shipping executable. Test ordinary completion, Esc cancellation, nonempty
field refusal, target changes, and persistence after Modore relaunch.
