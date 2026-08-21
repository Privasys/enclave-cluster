#!/bin/bash
# Copyright (c) Privasys. All rights reserved.
# Licensed under the GNU Affero General Public License v3.0. See LICENSE file for details.
#
# Multi-node end-to-end: a three-node cluster on one SGX machine, with
# the cluster credential obtained from a vault constellation — the only
# way a cluster gets its key. Asserted from the logs:
#
#   1. Node 1 CREATES the credential (it carries the key-creation
#      grant), Shamir-split across the constellation.
#   2. Nodes 2 and 3 hold NO grant: they are admitted by attestation
#      alone and reconstruct the key.
#   3. All nodes read the admissible measurement set from the
#      credential policy (the policy is the upgrade source of truth).
#   4. A leader is elected and entries are quorum-verified (peer links
#      are mutual challenge-mode RA-TLS).
#   5. Node 1 restarts and REFETCHES the credential under the policy
#      (there is no node-local copy — every boot is re-admitted) and
#      rejoins.
#   6. Fail-closed negative: a node presenting an identity the policy
#      does not pin (wrong app id) cannot obtain the credential and
#      never joins.
#
# Requirements
#   - An SGX machine with DCAP quoting; run as a user in `sgx_prv`.
#   - A built release: enclave.signed.so + enclave-os-host (defaults
#     below point at this repository's build output).
#   - Platform prerequisites, prepared by an operator beforehand:
#       * this build's MRENCLAVE registered as an approved platform
#         enclave (the vault directory serves approved enclaves only),
#       * a key-creation grant for the credential, minted for a policy
#         that pins this MRENCLAVE (grants are valid ~15 minutes —
#         mint one right before running).
#
# Parameters (environment)
#   E2E_MGMT_URL      management-service base URL   (directory mode)
#   E2E_ENVIRONMENT   vault directory environment   (directory mode)
#   E2E_CONSTELLATION inline constellation JSON     (direct/BYOK mode;
#                     replaces the two above: {"endpoints": [...],
#                     "mrenclave", "attestation_server", "ca_roots",
#                     "threshold", "oidc_issuer",
#                     "acceptable_tcb_statuses"} — no platform
#                     directory involved, no enclave registration
#                     needed)
#   E2E_HANDLE        credential handle, under the grant's
#                     app scope, e.g.
#                     apps.privasys.org/<app-id>/raft-ck   (required)
#   E2E_GRANT         key-creation grant JWT               (required)
#   E2E_APP_ID        app id (hex) the grant is scoped to  (required)
#   E2E_AS_URL        attestation-server URL (exact string
#                     the platform serves, incl. any path)  (required)
#   E2E_AS_TOKEN_FILE bearer-token file for the AS          (required)
#   E2E_TCB_ACCEPT    acceptable TCB statuses, JSON array
#                     (default: ["ConfigurationAndSWHardeningNeeded"])
#   E2E_HOST_BIN      host binary        (default: repo build output)
#   E2E_ENCLAVE       signed enclave     (default: repo build output)
#   E2E_WORKDIR       scratch directory  (default: ./e2e-work)
#   E2E_BASE_PORT     first ingress port (default: 9601; peers +100)

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN=${E2E_HOST_BIN:-$REPO/enclave-os-mini/target/release/enclave-os-host}
ENCLAVE=${E2E_ENCLAVE:-$REPO/enclave-os-mini/build/bin/enclave.signed.so}
WORK=${E2E_WORKDIR:-$REPO/e2e-work}
BASE=${E2E_BASE_PORT:-9601}
TCB=${E2E_TCB_ACCEPT:-'["ConfigurationAndSWHardeningNeeded"]'}

for var in E2E_HANDLE E2E_GRANT E2E_APP_ID E2E_AS_URL E2E_AS_TOKEN_FILE; do
  if [ -z "${!var:-}" ]; then
    echo "missing $var (see the header of this script)" >&2
    exit 2
  fi
done
if [ -z "${E2E_CONSTELLATION:-}" ] \
   && { [ -z "${E2E_MGMT_URL:-}" ] || [ -z "${E2E_ENVIRONMENT:-}" ]; }; then
  echo "set E2E_MGMT_URL + E2E_ENVIRONMENT (directory) or E2E_CONSTELLATION (direct)" >&2
  exit 2
fi

vault_block() { # grant app_id -> the raft_vault JSON object
  local grant=$1 app_id=$2
  if [ -n "${E2E_CONSTELLATION:-}" ]; then
    echo "{\"constellation\": $E2E_CONSTELLATION, \"handle\": \"$E2E_HANDLE\", \"grant\": \"$grant\", \"app_id\": \"$app_id\"}"
  else
    echo "{\"mgmt_url\": \"$E2E_MGMT_URL\", \"environment\": \"$E2E_ENVIRONMENT\", \"handle\": \"$E2E_HANDLE\", \"grant\": \"$grant\", \"app_id\": \"$app_id\"}"
  fi
}
[ -x "$HOST_BIN" ] || { echo "host binary not found: $HOST_BIN" >&2; exit 2; }
[ -f "$ENCLAVE" ] || { echo "enclave not found: $ENCLAVE" >&2; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$WORK"

# Throwaway fleet CA: possession is the fleet credential, so the three
# local nodes simply share a fresh one.
if [ ! -f "$WORK/ca.crt.pem" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/ca.key.pem" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$WORK/ca.key.pem" -out "$WORK/ca.pkcs8.pem"
  openssl req -new -x509 -key "$WORK/ca.key.pem" -subj "/CN=e2e-fleet-ca" \
    -days 2 -out "$WORK/ca.crt.pem" 2>/dev/null
fi

stop_nodes() {
  for f in "$WORK"/n*.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    rm -f "$f"
  done
  sleep 1
}
trap stop_nodes EXIT

peers_for() { # id -> peer map of the OTHER nodes
  local id=$1 out="{" sep=""
  for other in 1 2 3; do
    [ "$other" = "$id" ] && continue
    out="$out$sep\"$other\": \"127.0.0.1:$((BASE + 100 + other - 1))\""
    sep=", "
  done
  echo "$out}"
}

start_node() { # id with_grant(0|1)
  local id=$1 with_grant=$2
  local grant=""
  [ "$with_grant" = 1 ] && grant=$E2E_GRANT
  mkdir -p "$WORK/n$id"
  cd "$WORK/n$id" || exit 1
  nohup "$HOST_BIN" \
    --enclave-path "$ENCLAVE" \
    --port $((BASE + id - 1)) --peer-port $((BASE + 100 + id - 1)) \
    --kv-path kv \
    --ca-cert "$WORK/ca.crt.pem" --ca-key "$WORK/ca.pkcs8.pem" \
    --egress-ca-bundle /etc/ssl/certs/ca-certificates.crt \
    --attestation-servers "$E2E_AS_URL" \
    --attestation-token-file "$E2E_AS_TOKEN_FILE" \
    --extra "{
      \"raft_node_id\": $id,
      \"raft_peers\": $(peers_for "$id"),
      \"raft_vault\": $(vault_block "$grant" "$E2E_APP_ID"),
      \"raft_acceptable_tcb_statuses\": $TCB,
      \"raft_log_retain\": 64
    }" > node.log 2>&1 &
  echo $! > "$WORK/n$id.pid"
}

wait_log() { # file pattern timeout_s
  local f=$1 pat=$2 t=$3
  for _ in $(seq 1 "$t"); do
    grep -q "$pat" "$f" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

echo "=== 1. node 1 creates the cluster credential (grant) ==="
stop_nodes
rm -rf "$WORK"/n1 "$WORK"/n2 "$WORK"/n3 "$WORK"/n4
start_node 1 1
if wait_log "$WORK/n1/node.log" "cluster key resolved from the vault constellation" 120; then
  ok "credential created on the constellation"
else
  fail "node 1 did not obtain the credential"
  grep -iE "error|raft" "$WORK/n1/node.log" | tail -n 10
  exit 1
fi

echo "=== 2. nodes 2 and 3 are admitted by attestation (no grant) ==="
start_node 2 0
start_node 3 0
for id in 2 3; do
  if wait_log "$WORK/n$id/node.log" "cluster key resolved from the vault constellation" 120; then
    ok "node $id reconstructed the key by attestation alone"
  else
    fail "node $id was not admitted"
    grep -iE "error|raft" "$WORK/n$id/node.log" | tail -n 10
    exit 1
  fi
done

echo "=== 3. the admissible measurement set comes from the policy ==="
for id in 1 2 3; do
  # The policy fetch happens moments after key resolution — wait, don't
  # sample.
  if wait_log "$WORK/n$id/node.log" "measurement set from policy" 60; then
    ok "node $id pin set sourced from the credential policy"
  else
    fail "node $id did not read the policy pin set"
  fi
done

echo "=== 4. leader election + quorum verification ==="
if wait_log "$WORK/n1/node.log" "role=Leader" 45 \
   || wait_log "$WORK/n2/node.log" "role=Leader" 5 \
   || wait_log "$WORK/n3/node.log" "role=Leader" 5; then
  ok "leader elected"
else
  fail "no leader"
  exit 1
fi
verified_ok=0
for _ in $(seq 1 30); do
  if grep -hE "verified=[1-9]" "$WORK"/n*/node.log | grep -q .; then
    verified_ok=1
    break
  fi
  sleep 1
done
[ "$verified_ok" = 1 ] && ok "entries quorum-verified" || fail "verified index never advanced"

echo "=== 5. node 1 restarts and refetches under the policy ==="
kill "$(cat "$WORK/n1.pid")" 2>/dev/null
rm -f "$WORK/n1.pid"
sleep 2
start_node 1 0
if wait_log "$WORK/n1/node.log" "cluster key resolved from the vault constellation" 120; then
  ok "restart refetched the credential (no node-local copy)"
else
  fail "node 1 did not refetch the credential on restart"
fi
if wait_log "$WORK/n1/node.log" "leader=Some" 60; then
  ok "node 1 rejoined the cluster"
else
  fail "node 1 did not rejoin"
fi

echo "=== 6. fail-closed: an unpinned identity cannot obtain the credential ==="
# Same build, but presenting an app id the policy does not bind (OID
# 3.6 mismatch): every vault must refuse the export, so the node has
# no key and never boots the cluster module.
if [ "${E2E_APP_ID:0:1}" = "0" ]; then
  BAD_APP_ID="f${E2E_APP_ID:1}"
else
  BAD_APP_ID="0${E2E_APP_ID:1}"
fi
mkdir -p "$WORK/n4"
cd "$WORK/n4" || exit 1
nohup "$HOST_BIN" \
  --enclave-path "$ENCLAVE" \
  --port $((BASE + 3)) --peer-port $((BASE + 103)) \
  --kv-path kv \
  --ca-cert "$WORK/ca.crt.pem" --ca-key "$WORK/ca.pkcs8.pem" \
  --egress-ca-bundle /etc/ssl/certs/ca-certificates.crt \
  --attestation-servers "$E2E_AS_URL" \
  --attestation-token-file "$E2E_AS_TOKEN_FILE" \
  --extra "{
    \"raft_node_id\": 4,
    \"raft_peers\": {\"1\": \"127.0.0.1:$((BASE + 100))\"},
    \"raft_genesis_voters\": [1, 2, 3],
    \"raft_vault\": $(vault_block "" "$BAD_APP_ID"),
    \"raft_acceptable_tcb_statuses\": $TCB,
    \"raft_log_retain\": 64
  }" > node.log 2>&1 &
echo $! > "$WORK/n4.pid"
if wait_log "$WORK/n4/node.log" "raft: cluster credential:" 120; then
  if grep -q "cluster key resolved from the vault constellation" "$WORK/n4/node.log"; then
    fail "unpinned identity obtained the credential"
  else
    ok "unpinned identity refused fail-closed (no credential, no cluster)"
  fi
else
  fail "node 4 produced no credential error (unexpected)"
  grep -iE "error|raft" "$WORK/n4/node.log" | tail -n 10
fi

stop_nodes
echo
echo "=== e2e: $PASS ok, $FAIL failed ==="
[ "$FAIL" = 0 ]
