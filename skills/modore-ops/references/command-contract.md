# Modore command contract

## Session continuity

```bash
modore sessions --limit 50
modore search --limit 20 --budget-seconds 30  # query bytes arrive on stdin
```

`sessions` reads metadata only. `search` is the explicit content-reading path;
snippets remain masked unless a user separately invokes lower-level raw mode.
The agent surface defaults session listing to 50 and caps it at 500; search is
capped at 200 matches, a 55-second internal budget, a 60-second outer wall
clock, and a 4096-byte UTF-8 query. Session listing has a 30-second outer wall
clock. Do not put the search phrase in shell history, process arguments, or a
temporary file.

Backup, verification, restore, and detailed inspection remain available through
the Modore app and `scripts/scree.py`. Those operations require an exact named
source or archive; do not infer one from a transcript.

## Storage

```bash
modore storage status
modore cleanup list
modore storage recovery
```

`status` samples free space and the bounded drop evidence. `cleanup list` only
names fixed recipes; it does not create an approval token. `storage recovery`
opens the native Modore recovery plan with no target, tier, approval, or
execution flag; the app remeasures and asks the user before it changes data.
The agent command intentionally has no full-system scan or cleanup-preview
route: the former would collect unrelated security metadata, while the latter
would mint a live destructive approval token.

## Agent access

```bash
modore mcp tools
```

This prints the read-only MCP surface. Do not register it globally without the
user choosing that boundary: results may contain local paths, process names, and
masked excerpts that the invoking client can send to its model provider.
