# Contributing

Thank you for your interest in Enclave Cluster.

## Where code lives

This repository is the **product**: build pipeline, releases,
measurement registry, operator documentation and multi-node tests. The
runtime code — the consensus core (`enclave-os-raft`), the
authenticated ledger (`enclave-os-merkle`), the WASM runtime and the
enclave itself — lives in
[enclave-os-mini](https://github.com/Privasys/enclave-os-mini), pinned
here as a submodule. Bug fixes and features in those components belong
there; this repository takes them by advancing the pin in a reviewed
commit.

## Building and testing

```bash
git clone --recursive https://github.com/Privasys/enclave-cluster.git
cd enclave-cluster

# Reproducible enclave build (requires Docker):
./docker/build-cluster.sh

# Component tests run anywhere (no SGX needed):
cd enclave-os-mini/crates/enclave-os-raft   && cargo test
cd ../enclave-os-merkle                     && cargo test
```

Multi-node end-to-end testing requires an SGX machine with DCAP
quoting AND access to a vault constellation for the cluster
credential (there is no config-supplied key).
[scripts/e2e.sh](scripts/e2e.sh) runs the full three-node scenario —
credential creation with the grant, attestation-only admission,
policy-sourced measurement set, quorum verification, restart
re-admission, fail-closed refusal of an unpinned identity —
parameterised by environment variables (see the script
header): the platform prerequisites are a registered MRENCLAVE for
your build and a freshly minted key-creation grant.

## Pull requests

- Keep changes focused; one concern per PR.
- Advancing the submodule pin is its own PR, stating the
  enclave-os-mini revision range it takes and why.
- CI must be green: the reproducible build and the component tests run
  on every PR.
- Commit messages follow conventional commits
  (`feat: …`, `fix: …`, `docs: …`).

## Releases

Maintainers tag `cluster-vX.Y.Z`; CI builds reproducibly, extracts the
MRENCLAVE and attaches the signed enclave, host binary and build
manifest to the GitHub release. Because peer links pin the measurement,
every release note must state the rotation impact (see the upgrade
runbook in [docs/operations.md](docs/operations.md)).

## License

By contributing you agree that your contributions are licensed under
the [AGPL-3.0](LICENSE).
