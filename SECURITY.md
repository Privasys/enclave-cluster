# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately to
**security@privasys.org**. Do not open public issues for security
reports. We aim to acknowledge reports within 48 hours and to keep you
informed of progress; coordinated disclosure timelines are agreed per
report.

Please include what you can: affected release (or commit), the flavor
and configuration, reproduction steps, and impact assessment.

## Scope

This repository packages the cluster flavor of
[enclave-os-mini](https://github.com/Privasys/enclave-os-mini). Reports
against the runtime components (consensus, ledger, WASM runtime,
enclave, host) are equally welcome here or there — we will route them.

Of particular interest, given the threat model (the host is the
adversary; see [docs/architecture.md](docs/architecture.md)):

- rollback or replay attacks the incarnation gate, verified commits or
  commit certificates fail to detect;
- divergence between replicas that quorum root confirmation misses;
- peer-link authentication bypasses (fleet CA or measurement pinning);
- fail-open behaviour anywhere a fail-closed response is documented.

## Supported versions

Security fixes land on the latest `cluster-v*` release line. Because
peer links pin the enclave measurement, clusters must upgrade as a
fleet (rotation runbook in [docs/operations.md](docs/operations.md));
we keep that procedure in mind when scoping fixes.
