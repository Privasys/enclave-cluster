# Operations

Configuration reference and runbooks for running an Enclave Cluster.

## Host flags

| Flag | Purpose |
| --- | --- |
| `--port` | HTTPS ingress (RA-TLS, client API) |
| `--peer-port` | Cluster peer links (mutual TLS between enclaves) — also enables the tick source |
| `--kv-path` | Local storage directory (RocksDB) |
| `--ca-cert` / `--ca-key` | The fleet intermediary CA (same pair on every node; required on first run, sealed thereafter) |
| `--oidc-issuer` / `--oidc-audience` | OIDC for the client API (`raft_*` envelopes) |
| `--egress-ca-bundle` | Root CAs for outbound HTTPS (JWKS fetch, WASM egress, attestation-server calls) |
| `--attestation-servers` | Attestation server URL(s) for independent peer-quote verification (recommended) |
| `--attestation-token-file` | Bearer token for the attestation server(s). Token lookup is exact-URL: this flag's URL string must match the server's configured endpoint verbatim (including any path such as `/verify`) |
| `--extra '<json>'` | Cluster configuration, merged into the enclave config (below) |

Run each node from its own working directory: the sealed configuration
blob is written relative to it.

## Cluster configuration (`--extra`)

| Key | Required | Meaning |
| --- | --- | --- |
| `raft_node_id` | yes | This node's id (u64, unique; joiners take ids higher than existing nodes) |
| `raft_peers` | yes | `{"<id>": "host:port", ...}` — peer-port addresses of the other nodes |
| `raft_vault` | one of | Managed mode: the cluster key lives in a vault constellation (see below). `{"mgmt_url", "environment", "handle", "grant", "app_id"}` |
| `raft_cluster_key` | one of | Standalone mode: 64-hex shared secret; the ledger commitment key derives from it. The host sees this value — prefer `raft_vault` where available |
| `raft_genesis_voters` | joiners | The cluster's founding voter ids (the joiner NOT among them) |
| `raft_log_retain` | no | Applied entries to keep in the log (default 1024; compaction triggers at twice this) |
| `raft_pin_measurements` | no | Admissible peer MRENCLAVEs (hex list). Default: in managed mode, the credential policy's measurement set (refreshed every 10 minutes); otherwise this build's own measurement. Standalone clusters list {old, new} here during an upgrade window |
| `raft_pin_measurement` | no | Set `false` to disable the measurement pin entirely (weakens the trust model; transitional use only) |
| `raft_acceptable_tcb_statuses` | no | Intel TCB statuses accepted on peer quotes beyond the secure floor (`UpToDate`/`SWHardeningNeeded`). Absent = no TCB check; `[]` = strict floor-only; `Revoked` is never accepted and may not be listed |
| `raft_reattest_secs` | no | Link max age before recycling for a fresh quote (default 86400; 0 disables) |

## Peer admission

Every peer link passes three checks:

1. **Fleet + measurement pin (TLS layer)** — the peer's certificate
   chains to the fleet CA, its embedded SGX quote's MRENCLAVE is in
   the admissible set, and the quote is cryptographically bound to the
   certificate's own key (a quote copied from another node's public
   certificate is rejected).
2. **Attestation-server verification** — when `--attestation-servers`
   is configured, the peer's quote is independently verified
   (signature chain to the Intel root, QE identity, revocation, DEBUG
   flag) and its Intel TCB status is gated by
   `raft_acceptable_tcb_statuses`. Verification failures close the
   link (fail-closed); verdicts are cached, and rejected peers are
   re-checked within a minute so a TCB recovery is picked up.
3. **Re-attestation** — links older than `raft_reattest_secs` are
   recycled; certificates are minted per connection, so recycling
   forces fresh quotes on both sides.

Configure the acceptable TCB set deliberately: most real fleets report
`ConfigurationAndSWHardeningNeeded` (host BIOS settings outside your
control), so a strict floor-only set will reject them. Accepting a
status below the floor is a documented, auditable decision.

## Managed mode: the vault-anchored cluster key

With `raft_vault`, the cluster key never appears in any configuration
or on any host. The first node generates it inside its enclave,
splits it across the vault constellation (no single vault holds the
whole key), and every later node obtains it by attestation alone: the
vaults release a share only to an enclave that passes the key
policy's measurement, certificate and TCB checks. **Obtaining the
credential is cluster admission.**

- `handle` names the key, under the scope of the `app_id` the grant
  was minted for (e.g. `apps.privasys.org/<app-id>/raft-ck`).
- `grant` (a key-creation grant minted by the platform, valid 15
  minutes) is needed only on the very first boot of the first node.
  Every other node and boot omits it. The grant is an authorisation
  token, not secret material: spending it requires passing the
  policy's attestation checks over mutual RA-TLS.
- After the first fetch each node seals its copy under its own master
  key: restarts do not depend on vault availability.
- The cluster's MRENCLAVE must be registered as an approved platform
  enclave before its nodes can discover the constellation.
- The policy's attestation-server URL and the node's
  `--attestation-servers` value must both match the platform's
  configured endpoint string exactly (including the path).
- **The policy is the source of truth for peer admission**: unless an
  explicit `raft_pin_measurements` list is configured, every node
  reads the admissible measurement set from the credential policy's
  TEE profiles at startup and re-reads it every 10 minutes. A node
  that boots from its sealed key copy while the vaults are unreachable
  starts with an own-measurement-only set and widens it at the next
  successful refresh.

## Bootstrap (founding a cluster)

1. Generate the fleet CA and the cluster key; distribute both to every
   founding node (the cluster key is a secret — treat it like one).
2. Start all founders with complete `raft_peers` maps and **no**
   `raft_genesis_voters` (founders default to "all configured nodes are
   voters", admitted at genesis).
3. A leader emerges within seconds. Verify with `raft_status`: one
   `"role":"leader"`, identical `ledger_root` everywhere, `verified`
   tracking `commit`.

## Adding a node

1. Pick an id **higher** than any existing node's (the higher id dials,
   so a joiner reaches every founder).
2. Start it with the full peer map, the cluster key, and
   `raft_genesis_voters` set to the founding voter list.
3. On the leader: `{"raft_add_learner":{"node":<id>}}` — the node
   catches up by replication, or by snapshot if the log has compacted
   past it (automatic either way).
4. When `raft_status` on the new node shows it caught up:
   `{"raft_promote":{"node":<id>}}`. The promotion records the
   incarnation the leader observed; the node is now a voter.

## Removing a node

`{"raft_remove":{"node":<id>}}` retires the node's vote, incarnation
record and signing key in one committed change, then stop the process.
Quorum shrinks accordingly.

## Restarts and repair (mostly automatic)

- **Restart**: the node recovers from its encrypted log and ledger
  checkpoint, rejoins as a non-voting participant, and the leader
  re-admits it automatically (a committed incarnation refresh). No
  operator action.
- **Lagging node**: if the cluster compacted past it, the leader
  streams a snapshot automatically; stalled transfers retry.
- **Diverged ledger** (root verification failed): the node repairs
  itself once per boot by deterministic replay of its committed log; if
  divergence recurs, it halts and needs an operator (this indicates a
  real defect, not a transient).
- **Full-cluster restart**: recovers on its own after the recovery
  timeout (~10 s of leaderless quiet); nothing to do but wait.

Watch the logs: every consensus transition is one line
(`raft: role=... term=... leader=... commit=... verified=...`), and all
snapshot/repair activity is logged explicitly.

## Upgrading a cluster (measurement rotation)

Peer links pin the enclave measurement, so nodes running different
releases will refuse each other. Upgrades open a two-measurement
window instead of disabling the pin.

**Managed mode — no node configuration is touched at any point:**

1. Note the new release's MRENCLAVE (published with every release)
   and register it as an approved platform enclave.
2. The key owner approves the new measurement on the cluster
   credential's policy (adds a TEE profile for it). Within the
   10-minute refresh window every running node widens its admissible
   set to {old, new}; a new-release node cannot obtain the cluster
   key a moment earlier.
3. Rolling restart, one node at a time, with the new binary.
   Restarted nodes fetch the key (the policy now admits them), rejoin
   through the normal re-admission path (log replication or snapshot
   streaming), and quorum survives throughout.
4. When every node runs the new release, the owner retires the old
   measurement from the policy. Running nodes narrow their sets on
   the next refresh; old binaries can no longer peer nor obtain the
   key.

To abort mid-roll, remove the NEW measurement from the policy instead
and roll the upgraded nodes back.

**Standalone mode** (config-supplied key): the same window is driven
by configuration — restart each node with
`"raft_pin_measurements": ["<old>", "<new>"]` and the new binary,
then restart with `["<new>"]` (or drop the key) once the roll is
complete. The legacy escape hatch (`"raft_pin_measurement": false`)
still exists but drops the measurement gate entirely — the
two-measurement window makes it unnecessary.

## Monitoring

- `raft_status` (monitoring role) per node: alert on `halted: true`, on
  `verified` lagging `commit` persistently, on a missing leader, and on
  `ledger_root` mismatch across nodes at the same version.
- `raft_certificate` (monitoring role): the freshest quorum-signed
  state attestation — archive these for audit
  (see [certificates.md](certificates.md)).
- `/healthz` is unauthenticated liveness; `/status` and `/metrics`
  carry the standard Enclave OS surface.

## Storage layout

Cluster state lives in two tables of the node-local store, both
encrypted with node-local keys derived from the sealed master key: the
Raft log (`raft:log` — entries with index-bound authentication, hard
state, membership base, applied floor) and the ledger
(`raft:ledger` — the Merkle tree). Neither is portable between nodes;
state moves only through replication and snapshots.
