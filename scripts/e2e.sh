#!/usr/bin/env bash
# Copyright (c) Privasys. All rights reserved.
# Licensed under the GNU Affero General Public License v3.0. See LICENSE file for details.
#
# Multi-node end-to-end smoke test on ONE SGX machine: founds a
# three-node cluster with a throwaway fleet CA, waits for election and
# quorum verification, then exercises restart recovery.
#
# Requirements: SGX with DCAP quoting (user in the sgx_prv group), a
# built release (BIN dir with enclave.signed.so + enclave-os-host).
#
# Usage:
#   BIN=enclave-os-mini/build/bin ./scripts/e2e.sh
#
# The authenticated API (transactions, membership, certificates) needs
# an OIDC issuer + manager token and is exercised separately; this
# script asserts everything visible without authentication: election,
# replication, quorum verification and restart re-admission, all from
# the consensus transition logs.

set -euo pipefail

BIN="${BIN:?set BIN to the directory holding enclave.signed.so + enclave-os-host}"
BIN="$(cd "${BIN}" && pwd)"
WORK="$(mktemp -d /tmp/enclave-cluster-e2e.XXXXXX)"
echo "==> Workdir: ${WORK}"
cd "${WORK}"

cleanup() {
    for p in "${PIDS[@]:-}"; do kill "${p}" 2>/dev/null || true; done
}
trap cleanup EXIT

# Fleet CA + cluster key
openssl ecparam -name prime256v1 -genkey -noout -out ca.key.pem 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in ca.key.pem -out ca.pkcs8.pem
openssl req -new -x509 -key ca.key.pem -subj "/CN=e2e-fleet-ca" -days 2 -out ca.crt.pem 2>/dev/null
CK=$(openssl rand -hex 32)

PIDS=()
launch() {
    local n=$1 port=$2 pport=$3 peers=$4
    mkdir -p "n${n}" && cd "n${n}"
    RUST_LOG=info "${BIN}/enclave-os-host" \
        --enclave-path "${BIN}/enclave.signed.so" \
        --port "${port}" --peer-port "${pport}" --kv-path kv \
        --ca-cert ../ca.crt.pem --ca-key ../ca.pkcs8.pem \
        --extra "{\"raft_node_id\":${n},\"raft_peers\":${peers},\"raft_cluster_key\":\"${CK}\",\"raft_log_retain\":64}" \
        > host.log 2>&1 &
    PIDS+=($!)
    cd ..
}

launch 1 9611 9711 '{"2":"127.0.0.1:9712","3":"127.0.0.1:9713"}'
launch 2 9612 9712 '{"1":"127.0.0.1:9711","3":"127.0.0.1:9713"}'
launch 3 9613 9713 '{"1":"127.0.0.1:9711","2":"127.0.0.1:9712"}'

wait_for() { # <pattern> <file> <seconds>
    local i
    for i in $(seq 1 "$3"); do
        grep -q "$1" "$2" 2>/dev/null && return 0
        sleep 1
    done
    echo "TIMEOUT waiting for '$1' in $2" >&2
    tail -20 "$2" >&2 || true
    return 1
}

echo "==> Waiting for election + quorum verification..."
wait_for 'role=Leader'  n1/host.log 30 || wait_for 'role=Leader' n2/host.log 5 || wait_for 'role=Leader' n3/host.log 5
for n in 1 2 3; do
    wait_for 'commit=1 verified=1' "n${n}/host.log" 30
done
echo "    OK: leader elected, noop committed and quorum-verified on all nodes"

echo "==> Restarting node 3 (restore + live re-admission)..."
kill "${PIDS[2]}"; sleep 2
launch 3 9613 9713 '{"1":"127.0.0.1:9711","2":"127.0.0.1:9712"}'
wait_for 'restored' n3/host.log 20
# Re-admission = a committed config entry: commit advances past 1.
wait_for 'commit=2' n3/host.log 30
echo "    OK: node 3 restored and re-admitted (incarnation refresh committed)"

echo "==> PASS"
