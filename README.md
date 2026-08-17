# Enclave Cluster

**Multi-active confidential computing**: a cluster of SGX enclaves that
execute WASM business logic against a replicated, authenticated ledger —
with every state change ordered by consensus, verified by a quorum, and
provable to third parties.

Enclave Cluster is the distributed flavor of
[Enclave OS (Mini)](https://github.com/Privasys/enclave-os-mini),
built out-of-tree from a pinned revision with the `merkle`, `raft`,
`wasm` and `fido2` modules enabled. This repository owns the product:
the reproducible build, the release pipeline and measurement registry,
the operator documentation, and the multi-node end-to-end tests.

## What you get

- **Authenticated replicated ledger** — a versioned sparse Merkle tree
  whose 32-byte root attests the entire logical state. The root is
  *encryption independent*: every node encrypts its storage with its own
  key, yet all nodes produce byte-identical roots, so replicas compare
  state as `(version, root)`.
- **Attested Raft consensus** — only enclaves whose measurement is in
  the cluster's admissible set may participate: peer links are mutual
  TLS between enclaves, the peer's SGX quote is pinned to its
  certificate key, and (when configured) independently verified by an
  attestation server, including the platform's Intel TCB status
  against an explicit acceptance policy. The classic host attacks on
  Raft are closed by design: a rolled-back node cannot double-vote
  (incarnation-gated voting), and a node whose state diverges from the
  quorum is detected and repaired, not trusted.
- **Vault-anchored cluster credential** (managed mode) — the shared
  ledger commitment key is generated in-enclave, split across a vault
  constellation, and released to a node only if it passes the key
  policy's measurement + TCB checks. Obtaining the credential IS
  cluster admission; no shared secret ever appears in configuration.
  Standalone deployments can still supply the key by hand.
- **Verified commits** — every node reports the ledger root it computed
  for each applied entry; an entry is *verified* once a quorum agrees.
  Divergence is attributed (outlier follower, outlier leader, or
  genuine corruption) and handled automatically where safe.
- **Commit certificates** — quorum-signed P-256 attestations of
  `(index, root)`, verifiable offline against keys registered through
  the replicated log. Auditors can prove cluster state without trusting
  any single node. See [docs/certificates.md](docs/certificates.md).
- **Self-healing operations** — automatic log compaction, snapshot
  streaming to lagging or repaired nodes (cross-key: the receiver
  re-encrypts under its own storage key and verifies the advertised
  root), repair-by-replay for diverged ledgers, and live re-admission
  of restarted nodes.
- **WASM runtime** — the full Enclave OS component-model runtime for
  business logic, with the cluster transaction surface arriving next
  (fork the ledger, execute, commit through consensus).

## Quickstart (three local nodes)

Prerequisites: an SGX machine with DCAP quoting (the user needs the
`sgx_prv` group), a built release (see *Building*), and a fleet CA
(every node holds the same intermediary CA — possession is the fleet
credential).

```bash
# One-time: fleet CA and cluster commitment key
openssl ecparam -name prime256v1 -genkey -noout -out ca.key.pem
openssl pkcs8 -topk8 -nocrypt -in ca.key.pem -out ca.pkcs8.pem
openssl req -new -x509 -key ca.key.pem -subj "/CN=my-fleet-ca" -days 365 -out ca.crt.pem
CLUSTER_KEY=$(openssl rand -hex 32)

# Node 1 (repeat with ids 2 and 3, adjusting ports and peers)
enclave-os-host \
  --enclave-path enclave.signed.so \
  --port 9601 --peer-port 9701 --kv-path node1/kv \
  --ca-cert ca.crt.pem --ca-key ca.pkcs8.pem \
  --extra '{
    "raft_node_id": 1,
    "raft_peers": {"2": "10.0.0.2:9702", "3": "10.0.0.3:9703"},
    "raft_cluster_key": "'$CLUSTER_KEY'"
  }'
```

The cluster elects a leader within seconds; progress is visible in the
logs (`raft: role=... term=... commit=... verified=...`). This is the
standalone quickstart; production deployments should use the
vault-anchored credential (`raft_vault`) and attestation-server peer
verification instead — see [docs/operations.md](docs/operations.md)
for the full configuration reference, peer-admission model,
join/promote/remove flows, and runbooks.
[scripts/e2e.sh](scripts/e2e.sh) automates this whole scenario.

## API surface

Cluster operations ride the authenticated `POST /data` envelope
(OIDC-gated: reads need the monitoring role, writes the manager role):

| Envelope | Role | Purpose |
| --- | --- | --- |
| `raft_status` | monitoring | role, term, leader, commit/verified indexes, ledger `(root, version)`, membership |
| `raft_certificate` | monitoring | latest quorum certificate + registered keys |
| `raft_txn` | manager | propose a transaction (hex key/value ops; op without value = delete) |
| `raft_add_learner` / `raft_promote` / `raft_remove` | manager | membership changes |

```bash
curl -sk https://node:9601/data -H "Authorization: Bearer $JWT" \
  -d '{"raft_txn":{"ops":[{"key":"616c696365","value":"31303030"}]}}'
curl -sk https://node:9601/data -H "Authorization: Bearer $JWT" \
  -d '{"raft_status":{}}'
```

## Building

Releases are built reproducibly in the Enclave OS build container, from
the `enclave-os-mini` revision pinned by this repository's submodule:

```bash
git clone --recursive https://github.com/Privasys/enclave-cluster.git
cd enclave-cluster
./docker/build-cluster.sh          # → build/bin/enclave.signed.so + host binary
cat enclave-os-mini/build/mrenclave.txt
```

Every release tag (`cluster-v*`) publishes the signed enclave, the host
binary, the MRENCLAVE and a build manifest. Because peer links pin the
measurement, **all nodes of a cluster must run the same release**;
upgrades follow the rotation runbook in
[docs/operations.md](docs/operations.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) — trust model and design
- [docs/operations.md](docs/operations.md) — configuration and runbooks
- [docs/certificates.md](docs/certificates.md) — verifying commit certificates
- Enclave OS foundations: the
  [Merkle store](https://github.com/Privasys/enclave-os-mini/blob/main/docs/merkle-store.md)
  and [architecture](https://github.com/Privasys/enclave-os-mini/blob/main/docs/architecture.md)
  documents in the base repository

## License

[AGPL-3.0](LICENSE). Contributions welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
