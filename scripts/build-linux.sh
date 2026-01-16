#!/bin/bash
# build-linux.sh - Build all Linux variants (x64 or arm64)
#
# Builds ALL combinations of backends for Linux:
# - xnnpack
#
# Usage: ./build-linux.sh [VERSION]
# Example: ./build-linux.sh 1.0.1
#
# Architecture is auto-detected from host machine.

set -e

VERSION="${1:-1.0.1}"
PLATFORM="linux"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# Auto-detect architecture
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64)
    ARCH="x64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  *)
    echo "ERROR: Unsupported architecture: $HOST_ARCH"
    exit 1
    ;;
esac

# All variants to build: backends:vulkan
# NOTE: Vulkan is disabled for now - requires glslc compiler and complex shader compilation
# ExecuTorch's Vulkan build needs special setup (see their .ci/scripts/setup-vulkan-linux-deps.sh)
VARIANTS=(
  "xnnpack:OFF"
  # "xnnpack-vulkan:ON"  # TODO: Enable once Vulkan build is properly configured
)

echo "============================================================"
echo "ExecuTorch Linux Build Script"
echo "============================================================"
echo "  Version: ${VERSION}"
echo "  Platform: ${PLATFORM}"
echo "  Architecture: ${ARCH}"
echo "  Variants: ${#VARIANTS[@]}"
echo "============================================================"

# Install dependencies
install_dependencies() {
  echo ""
  echo "=== Installing dependencies ==="

  sudo apt-get update
  sudo apt-get install -y build-essential cmake ninja-build

  # Install Python dependencies
  pip install pyyaml torch --extra-index-url https://download.pytorch.org/whl/cpu

  # NOTE: Vulkan SDK not installed - not available for arm64 and Vulkan builds are disabled anyway

  echo "Dependencies installed successfully"
}

# Build a single variant
build_variant() {
  local backends=$1
  local vulkan=$2
  local build_type=$3
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-${PLATFORM}-${ARCH}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-${PLATFORM}-${ARCH}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ${PLATFORM}-${ARCH}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    -DEXECUTORCH_VERSION="${VERSION}" \
    -DEXECUTORCH_BUILD_MODE=source \
    -DEXECUTORCH_CACHE_DIR="${CACHE_DIR}" \
    -DET_BUILD_XNNPACK=ON \
    -DET_BUILD_VULKAN="${vulkan}" \
    -DET_BUILD_COREML=OFF \
    -DET_BUILD_MPS=OFF \
    -DET_BUILD_QNN=OFF \
    -DCMAKE_INSTALL_PREFIX="${build_dir}/install"

  # Build
  cmake --build "$build_dir" --parallel $(nproc)

  # Install
  cmake --install "$build_dir"

  # Package
  echo "Packaging ${artifact_name}..."
  cd "${build_dir}/install"
  tar -czvf "${PROJECT_DIR}/dist/${artifact_name}" .
  cd "$PROJECT_DIR"

  echo "Built: dist/${artifact_name}"
}

# Main
cd "$PROJECT_DIR"

# Install dependencies
install_dependencies

# Create dist directory
mkdir -p dist

# Build all variants
for variant in "${VARIANTS[@]}"; do
  IFS=':' read -r backends vulkan <<< "$variant"
  build_variant "$backends" "$vulkan" "Release"
  build_variant "$backends" "$vulkan" "Debug"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
