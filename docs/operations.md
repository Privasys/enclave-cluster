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
| `--egress-ca-bundle` | Root CAs for outbound HTTPS (JWKS fetch, WASM egress) |
| `--extra '<json>'` | Cluster configuration, merged into the enclave config (below) |

Run each node from its own working directory: the sealed configuration
blob is written relative to it.

## Cluster configuration (`--extra`)

| Key | Required | Meaning |
| --- | --- | --- |
| `raft_node_id` | yes | This node's id (u64, unique; joiners take ids higher than existing nodes) |
| `raft_peers` | yes | `{"<id>": "host:port", ...}` — peer-port addresses of the other nodes |
| `raft_cluster_key` | yes | 64-hex shared secret; the ledger commitment key derives from it, so all replicas must hold the same value |
| `raft_genesis_voters` | joiners | The cluster's founding voter ids (the joiner NOT among them) |
| `raft_log_retain` | no | Applied entries to keep in the log (default 1024; compaction triggers at twice this) |
| `raft_pin_measurement` | no | Peer measurement pinning (default `true`; disable only during a rotation) |

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
releases will refuse each other. To upgrade:

1. Restart every node with `"raft_pin_measurement": false` (rolling —
   the cluster stays available throughout).
2. Rolling-upgrade each node to the new release binary.
3. Restart every node with pinning re-enabled (remove the override).

Keep the unpinned window short; the fleet CA still gates peering during
it.

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
