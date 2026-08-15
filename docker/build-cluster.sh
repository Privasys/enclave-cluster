#!/usr/bin/env bash
# Copyright (c) Privasys. All rights reserved.
# Licensed under the GNU Affero General Public License v3.0. See LICENSE file for details.
#
# Reproducible Enclave Cluster build: runs the pinned enclave-os-mini
# submodule's build container with the cluster flavor flags
# (merkle + raft + wasm + fido2).
#
# Outputs (inside the submodule):
#   enclave-os-mini/build/bin/enclave.signed.so
#   enclave-os-mini/build/mrenclave.txt
#   enclave-os-mini/target/release/enclave-os-host
#
# Environment:
#   BUILD_IMAGE  — prebuilt builder image to use (default: build locally
#                  from the submodule's docker/Dockerfile.build)

set -euo pipefail
cd "$(dirname "$0")/.."

SUB="enclave-os-mini"
if [ ! -f "${SUB}/docker/build-enclave.sh" ]; then
    echo "ERROR: submodule not initialised — run: git submodule update --init" >&2
    exit 1
fi

CLUSTER_FLAGS="-DENABLE_WASM=ON -DENABLE_FIDO2=ON -DENABLE_MERKLE=ON -DENABLE_RAFT=ON"

IMAGE="${BUILD_IMAGE:-}"
if [ -z "${IMAGE}" ]; then
    IMAGE="enclave-cluster-build:local"
    echo "==> Building the builder image (${IMAGE})..."
    docker build -t "${IMAGE}" -f "${SUB}/docker/Dockerfile.build" "${SUB}"
fi

echo "==> Building Enclave Cluster (flavor flags: ${CLUSTER_FLAGS})..."
docker run --rm \
    -v "$(pwd)/${SUB}:/src" \
    -e CARGO_INCREMENTAL=0 \
    -e SOURCE_DATE_EPOCH=0 \
    -e FLAVOR=base \
    -e EXTRA_CMAKE_FLAGS="${CLUSTER_FLAGS}" \
    "${IMAGE}"

echo "==> MRENCLAVE:"
cat "${SUB}/build/mrenclave.txt"
