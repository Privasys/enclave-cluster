# Architecture

Enclave Cluster turns a set of SGX enclaves into one multi-active
system: every node executes the same ordered state changes against a
replicated authenticated ledger, and the cluster as a whole can prove
what its state is. This document describes the trust model and the
mechanisms; the operational procedures live in
[operations.md](operations.md).

## Trust model

Membership is measurement-gated: peer links are mutual challenge-mode
RA-TLS (TLS 1.3) terminated inside the enclaves, chained to a fleet CA
that only provisioned enclaves hold, and pinned to the cluster's
admissible measurement set. Each side issues a fresh challenge nonce
for every connection, and the peer's certificate must carry a quote
whose `report_data` commits to that nonce, the certificate's own key
and the TLS session's channel binder — evidence cannot be
transplanted between certificates, replayed from an earlier
connection, or relayed from another session.
When an attestation server is configured, each link's quote is also
verified independently of the fleet CA — signature chain to the Intel
root, QE identity, revocation, DEBUG flag, and the platform's Intel
TCB status against the cluster's acceptance policy — so even a stolen
fleet-CA key does not admit an attacker, and a platform downgraded
below the accepted TCB is refused. The shared ledger commitment key
itself is held by a vault constellation — the platform's, or a
customer-owned one addressed directly (BYOK) — and released only to
enclaves passing the same class of checks: obtaining the credential is
admission, re-established on every boot (nodes keep no local copy, so
revoking a measurement from the credential policy takes full effect at
the affected nodes' next restart), and no shared secret exists outside
TEEs. A node therefore cannot lie about the protocol — the code is
measured — and the adversary is each node's **host**, which can crash
the process, delay or drop traffic, partition the network, and roll
back anything the node persisted.

Plain Raft is not safe against that last power, so two hardenings make
the rollback-sensitive facts *cluster state* instead of local state:

1. **Incarnation-gated voting.** Every enclave start draws a fresh
   random incarnation, and the replicated membership records the
   incarnation under which each voter was admitted. A restarted node
   neither votes nor campaigns until the leader commits a re-admission
   for it — so a host that rolls back a vote record gains nothing: the
   restarted node's old voting identity is retired by the quorum, not
   by its own (rollback-able) disk. Full-cluster restart recovers
   through a long leaderless timeout that a single rolled-back node can
   never reach alone.
2. **Quorum root confirmation.** State continuity is confirmed by the
   quorum (below), so a rolled-back log cannot resurrect old state.

Liveness always remains host-controlled (a host can kill its process);
only safety is defended, and Raft's safety never depends on clocks.

## The ledger and the encryption-independent root

Each node maintains a versioned sparse Merkle tree over its local
storage. The tree commits to *keyed plaintext hashes* under a cluster
commitment key `ck` shared by all replicas, while the stored bytes are
AES-256-GCM ciphertext under a per-node storage key. The consequence is
the property everything else builds on: **replicas holding different
storage keys produce byte-identical roots**, so cluster state is
compared, verified and attested as a single `(version, root)` pair.
Reads are fail-closed — any record that does not verify against the
in-memory root is an error, never data.

## Transactions

A state change is a transaction: a sealed
`(root_before, write_set, root_after)` triple. The leader executes
against a fork of its committed ledger (reads fall through, writes are
buffered; the resulting root is computable without committing because
the tree math is pure), then proposes the transaction through Raft.
Every node applies the write-set and verifies the root transition; a
mismatch is divergence and fails closed **before** anything is
committed, so a diverged node keeps its last consistent state for
diagnosis and repair. Reads never touch consensus — they are served
locally at the committed root.

## Verified commits and dispute attribution

Alongside Raft's commit index the cluster maintains a **verified
index**: every node reports the ledger root it computed for each
applied entry, and an entry is verified once a quorum of voters agrees
on the root. Divergence is attributed rather than assumed:

- quorum agrees with the leader → the dissenting follower is the
  outlier: it stops serving and is repaired;
- a quorum of followers agrees against the leader → the leader is the
  outlier: it steps down and is repaired;
- nobody reaches a quorum → genuine corruption: the cluster halts for
  an operator.

## Commit certificates

Each node derives a P-256 signing key from its sealed master key and
announces the public key when a peer link establishes; the leader
registers keys through replicated config entries. Root reports are
signed, and the leader assembles a **commit certificate** — a quorum of
signatures over `(index, root)` — at the highest verified index. The
certificate is verifiable offline against the registered keys: one
invalid signature poisons it, and fewer than a quorum of voter
signatures fails it. See [certificates.md](certificates.md) for the
exact byte formats.

## Compaction, snapshots, and repair

Every node compacts its own log against a retention window. A node too
far behind the leader's compaction base cannot be served from the log,
so the leader streams it a **ledger snapshot**: path-ordered leaves,
one ack-paced chunk at a time, served from a version pinned against
pruning. The receiver rebuilds the store under its *own* storage key
and accepts the result only if the rebuilt root equals the advertised
one — cross-key state transfer with end-to-end verification. The same
mechanism serves brand-new learners and repaired outliers; a diverged
node with an intact local log can also repair itself by deterministic
replay. Transfers that stall are dropped and retried automatically.

## Membership lifecycle

New nodes join as learners (configured with the cluster's genesis
voters, not among them), catch up by replication or snapshot, and are
promoted to voters by the operator; removal retires the node's vote,
its incarnation record and its signing key in one committed change.
One membership change is in flight at a time.

## Time and networking

Peer traffic is multiplexed over each host's data-channel proxy —
sockets stay outside the enclave, TLS terminates inside. Election and
heartbeat timers are driven by proxy ticks (~100 ms); they are
host-supplied and deliberately so: only liveness depends on them.
Within a peer pair, only the higher node id dials, giving each pair
exactly one deterministic link.
