# Work resource policy verification

This document describes reproducible checks for the optional resource policy.
Keep account-specific hook state, provider session identifiers, conversation
receipts, local project paths, and live usage results outside the repository.

## Isolated verification

- Run the resource-policy, work-resource, tool-reuse, and CLI fixture suites.
- Verify that the native Swift request carries the assigned resource binding
  into the installed Codex executor using a temporary CODEX_HOME, an offline
  Responses fixture, a fake xcrun, and a fake MCP server.
- Verify that only the assigned simulator can be used. Deny wrong-simulator,
  physical-device, shell-wrapper, local-script, MCP, xcodebuild-destination,
  and pipe-to-shell attempts before execution.
- Exercise native request encoding and decoding, assignment labels, disconnect,
  and unchanged volume usage-lease behavior with temporary fixtures.
- Verify harmless heredoc text, bounded interpreter bodies, dangerous bodies,
  and quoted heredoc markers; heredoc data must not become shell tokens.
- Check localization keys and format signatures for changed resource UI.
- Tests must use fake device operations and must not mutate real simulators or
  physical devices. Each output directory must be newly created.

```sh
MODORE_PROBE_REQUEST_OUTPUT=/tmp/modore-app-request.json \
  swift test --package-path macos/Modore --filter WorkResourcePolicyTests
python3 tests/run_codex_resource_probe.py /tmp/modore-resource-probe \
  --app-request /tmp/modore-app-request.json
python3 -m pytest -q tests/test_resource_policy.py tests/test_work_resources.py \
  tests/test_tool_reuse.py tests/test_modore_cli.py
```

## Account-bound verification procedure

The isolated probe vets only its temporary hooks and may use a one-invocation
trust bypass. It does not establish or change trust in an installed account.
Account activation requires the account owner's hook review. Confirm normal
UserPromptSubmit, PreToolUse, and Stop lifecycle behavior in that host using
harmless marker fixtures and fake device tokens. CLI evidence alone cannot
establish the current desktop host's state. Do not publish account observations.

## Enforcement boundary

The policy inspects supported shell and MCP calls. It cannot prevent arbitrary
encoded or dynamically generated programs, policy edits by an unrestricted
process, unrelated UI automation, or a host that skips hooks. Stronger guarantees
require OS-level confinement.
