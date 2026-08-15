# Verifying commit certificates

A commit certificate is a quorum-signed attestation that the cluster
confirmed ledger state `(index, root)`. It can be verified offline,
with no connection to the cluster and no trust in the node that served
it — the signatures speak for a quorum of enclaves.

## Fetching

```bash
curl -sk https://node:9601/data -H "Authorization: Bearer $JWT" \
  -d '{"raft_certificate":{}}'
```

```json
{
  "certificate": {
    "index": 4,
    "root": "3cdb6cf4…",
    "sigs": { "1": "507dd9c1…", "2": "4fff9726…" }
  },
  "keys": {
    "1": "0319c980…",
    "2": "02cdb360…"
  },
  "quorum": 2
}
```

- `certificate.index` — the Raft log index the state corresponds to.
- `certificate.root` — the 32-byte ledger root (hex).
- `certificate.sigs` — per-node signatures, 64 bytes each (hex),
  P-256 ECDSA `r ‖ s`.
- `keys` — the signing keys registered in the replicated membership,
  compressed SEC1 P-256 points (33 bytes, hex).
- `quorum` — voter signatures required.

## Verification procedure

For each `(node, sig)` pair:

1. Build the signed preimage:
   `"enclave-os-raft:cert:v1" ‖ index (u64 little-endian) ‖ root (32 bytes)`.
2. Verify `sig` as ECDSA-P256/SHA-256 over the preimage against
   `keys[node]`.

The certificate is valid iff **every** included signature verifies
(one bad signature invalidates the whole certificate) **and** at least
`quorum` of the signers are cluster voters.

```python
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives import hashes

def verify(cert, keys, quorum):
    pre = b"enclave-os-raft:cert:v1" \
        + cert["index"].to_bytes(8, "little") \
        + bytes.fromhex(cert["root"])
    valid = 0
    for node, sig_hex in cert["sigs"].items():
        pub = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), bytes.fromhex(keys[node]))
        raw = bytes.fromhex(sig_hex)
        der = encode_dss_signature(
            int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        pub.verify(der, pre, ec.ECDSA(hashes.SHA256()))  # raises if invalid
        valid += 1
    return valid >= quorum
```

## What a certificate proves — and what anchors it

A valid certificate proves that a quorum of nodes holding the
registered keys computed the same ledger root after applying the log
through `index`. The keys themselves are registered through the
replicated log and derive from each enclave's sealed master key, so the
chain of trust bottoms out in the cluster's enclave measurement: obtain
the key set over an attested (RA-TLS) connection to any cluster node —
or pin it out of band — and the certificate then attests cluster state
with no further trust in any individual node.

Archive certificates alongside their key sets: together they form an
append-only, independently verifiable history of cluster state.
