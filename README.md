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
  challenge-mode RA-TLS between enclaves (each side's quote commits to
  the counterparty's fresh challenge nonce, the certificate key and
  the TLS session's channel binder), and (when configured)
  independently verified by an attestation server, including the
  platform's Intel TCB status against an explicit acceptance policy. The classic host attacks on
  Raft are closed by design: a rolled-back node cannot double-vote
  (incarnation-gated voting), and a node whose state diverges from the
  quorum is detected and repaired, not trusted.
- **Vault-anchored cluster credential** — the shared ledger commitment
  key is generated in-enclave, split across a vault constellation, and
  released to a node only if it passes the key policy's measurement +
  TCB checks. Obtaining the credential IS cluster admission,
  re-established on every boot (nodes keep no local copy, so a policy
  revocation is total at the next restart); no shared secret ever
  exists outside TEEs, and none appears in configuration.
- **Bring your own constellation (BYOK)** — the constellation can be
  customer-owned: supply its coordinates inline
  (`raft_vault.constellation`) instead of a directory URL, issue
  grants from your own IdP, and run your own attestation verifier. No
  platform control-plane dependency; every admission and upgrade
  property is preserved. Measurement profiles are TEE-typed (SGX
  MRENCLAVE or TDX MRTD/RTMRs) throughout.
- **Policy-driven upgrades** — the credential policy is the single
  source of truth for which enclave builds may participate: nodes
  read the admissible measurement set from it and refresh
  periodically, so a cluster upgrade is an owner-approved policy
  change plus a rolling restart — no node reconfiguration, and the
  measurement gate never drops. Verified live with two different
  builds forming one quorum-verified cluster.
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
- **WASM transactions** — business logic runs as Component Model apps
  against the replicated ledger: a call through the transaction path
  executes on a fork at the committed root
  (`privasys:enclave-os/ledger` imports), and the write-set commits
  through consensus. In **replay mode** replicas do not even trust the
  write-set: every node re-executes the call deterministically — one
  shared per-transaction DRBG behind `wasi:random`, clocks frozen to
  the committed timestamp, RFC 6979 signatures, fuel committed in the
  entry, and network imports rejected at load — and fails closed on
  any mismatch.

## Quickstart (three nodes)

There is no config-supplied cluster key: the ledger commitment key
lives in a vault constellation and every node obtains it by
attestation — fetching the credential IS cluster admission. One-time
setup on the platform: register the release's MRENCLAVE (published
with every release) as an approved platform enclave, and mint a
key-creation grant for the cluster credential (its policy pins the
measurement, the certificate identity, and the acceptable Intel TCB
statuses). Each node also needs an SGX machine with DCAP quoting (the
user in the `sgx_prv` group), a built release (see *Building*), and
the fleet CA (every node holds the same intermediary CA).

```bash
# Node 1. The grant is needed only on the FIRST boot of the first
# node — it creates the credential; every other node and boot omits
# it and is admitted by attestation alone.
enclave-os-host \
  --enclave-path enclave.signed.so \
  --port 9601 --peer-port 9701 --kv-path node1/kv \
  --ca-cert ca.crt.pem --ca-key ca.pkcs8.pem \
  --egress-ca-bundle /etc/ssl/certs/ca-certificates.crt \
  --attestation-servers <attestation-server-url> \
  --attestation-token-file /path/to/token \
  --extra '{
    "raft_node_id": 1,
    "raft_peers": {"2": "10.0.0.2:9702", "3": "10.0.0.3:9703"},
    "raft_vault": {
      "mgmt_url": "https://<management-service>",
      "environment": "production",
      "handle": "apps.privasys.org/<app-id>/raft-ck",
      "grant": "<key-creation grant, first boot of node 1 only>",
      "app_id": "<app-id-hex>"
    },
    "raft_acceptable_tcb_statuses": ["ConfigurationAndSWHardeningNeeded"]
  }'
```

The cluster elects a leader within seconds; progress is visible in the
logs (`raft: role=... term=... commit=... verified=...`). See
[docs/operations.md](docs/operations.md) for the full configuration
reference, the peer-admission model, the join/promote/remove flows,
and the runbooks.

## API surface

Cluster operations ride the authenticated `POST /data` envelope
(OIDC-gated: reads need the monitoring role, writes the manager role):

| Envelope | Role | Purpose |
| --- | --- | --- |
| `raft_status` | monitoring | role, term, leader, commit/verified indexes, ledger `(root, version)`, membership |
| `raft_certificate` | monitoring | latest quorum certificate + registered keys |
| `raft_txn` | manager | propose a transaction (hex key/value ops; op without value = delete) |
| `raft_wasm_txn` | manager | execute a WASM app export inside a cluster transaction (`{"app","function","params"}`) |
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
