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

# Multi-node end-to-end (requires an SGX machine with DCAP quoting):
./scripts/e2e.sh
```

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
