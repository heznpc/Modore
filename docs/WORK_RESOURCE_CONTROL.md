# Work resource control

The owner's unit is a working environment: an existing simulator, project/session,
and an external SSD with its actual users. Modore owns the inventory, resource
leases, actions and receipts. Taxi is not required.

## Entry points

- 작업 → 시뮬레이터·SSD 제어, or Command-Shift-K while in 작업.
- `modore resources status`: live devices, runtime IDs, duplicate groups, external
  volume UUIDs, open-file users, registered sessions, and stale connections.
- MCP `work_resource_status` exposes that inventory to sessions.
- `modore resources acquire --runtime <ID> --project <path> --session <ID>` selects
  an existing available simulator. It never creates a device. The preferred
  shared device wins within the requested OS/type, otherwise a booted one wins.
- `claim --id <UDID-or-volume-UUID> --project <path> --session <ID>` records use.
- `heartbeat --session <ID>` renews for fifteen minutes; `release` expires it.

The ops skill tells subsequent sessions to discover/reuse/register before
starting simulator work and to specify the returned UDID in every tool action.
Tools outside Modore cannot be forced to register. Names and historic session
workspace metadata do not prove ownership of a currently running simulator.
The UI explicitly separates registered connections, expired registrations, and
observed process cwd/open-file connections. It refreshes every ten seconds while
open. Project filtering provides an environment layer, with simulator/SSD tabs.

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

Before claiming a capability is missing, follow its existing collector, stored
result, UI and executor. Full storage collection already exists in
scripts/modules/macos/storage.sh; a bounded storage-watch status is not a
substitute for that full inventory. Existing simulator inventory and keep rules
remain separate from live resource/session registration. This change adds the
missing connection and control surface rather than replacing the storage scan.
