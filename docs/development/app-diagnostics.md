# Native app reproduction diagnostics

Open **앱 재현 검사** from the Modore window toolbar. Select a running app,
label the condition (for example long conversation vs short conversation), and
start. A nonactivating floating controller provides manual markers, an explicit
3-second stack capture, and stop/save. No TTS or timed instruction stages run.
The five-minute collection limit is shown before starting.

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
- The only optional child tool is `/usr/bin/sample`: explicit user request,
  3 seconds, at most three times, at least 30 seconds apart, with a watchdog.
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
- Automated replay end-to-end validation remains pending: the native UI tool
  disconnected while opening the diagnostic window (`native pipe closed before
  response`). No successful keyboard/hover replay is claimed from that run.
