# Storage watcher attribution

The minute watcher measures free space cheaply. Warning thresholds remain
20 GiB free or an 8 GiB drop within an hour. These thresholds are not the only
triggers for collecting evidence: gradual growth can consume significant disk
space while staying above both warning thresholds.

The watcher persists a free-space high-water baseline. A cumulative loss of
2 GiB triggers the existing bounded path/runtime capture even in normal state,
with a two-hour minimum interval between these additional captures. A path
capture advances the baseline; newly freed space raises it. Missing path
evidence preserves the baseline for a later retry. Low-space and rapid-drop
captures keep their existing higher-priority timing. Notification behavior is
unchanged.

On upgrade, the baseline may use free-space samples from the last 24 hours,
after the last capture. Those samples establish a disk-space delta only, not
historical sizes of individual folders. Path comparisons still require two
actual measurements of the same path. Capture coverage remains bounded and
may be partial; overlapping roots and process RSS must not be summed as disk
growth. There is no continuous whole-disk walk or automatic deletion.

Install caches are measured before slower agent and temporary roots. Within
each twelve-row event, npm retains one slot and pnpm/browser caches share one
slot, so their evidence is not discarded merely because unrelated persistent
folders are larger. `lastSnapshotReason` survives subsequent no-capture ticks.

Regression coverage exercises gradual loss below the warning thresholds,
capture cooldown, baseline advancement, and recovery after freeing space.

A partial normal-state cumulative capture now retries after two hours even
if some path rows already advanced the free-space baseline and no further
space was lost. The retry reason is `incomplete-cumulative-evidence`; after a
complete capture it stops. Path timestamps describe the rows actually saved,
not complete attribution. The retry uses the same bounded collection budget.
