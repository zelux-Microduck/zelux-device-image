#!/usr/bin/env bash
# Run on a Linux build host with Rust, cargo-zigbuild and Zig installed.
# Input is an exported independent robotd source tree, never a robot's live tree.
set -euo pipefail
source_root=${1:?usage: build-robotd-binaries.sh source-root target-dir}
target_dir=${2:?usage: build-robotd-binaries.sh source-root target-dir}
cd "$source_root"
export CARGO_TARGET_DIR="$target_dir"
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
cargo board --locked -p robotd -p robotctl --bins
readelf -h "$target_dir/aarch64-unknown-linux-gnu/release/robotd"
readelf -h "$target_dir/aarch64-unknown-linux-gnu/release/robotctl"
