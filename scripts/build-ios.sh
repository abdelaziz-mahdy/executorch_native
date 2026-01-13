#!/bin/bash
# build-ios.sh - Build all iOS arm64 variants
#
# Builds ALL combinations of backends for iOS arm64:
# - xnnpack
# - xnnpack-coreml
#
# Usage: ./build-ios.sh [VERSION]
# Example: ./build-ios.sh 1.0.1

set -e

VERSION="${1:-1.0.1}"
ARCH="arm64"
PLATFORM="ios"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# iOS: all combinations of coreml (2^1 = 2, no MPS/Vulkan)
# Format: backends:coreml
VARIANTS=(
  "xnnpack:OFF"
  "xnnpack-coreml:ON"
)

echo "============================================================"
echo "ExecuTorch iOS Build Script"
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

  # Install Ninja for faster builds
  brew install ninja || true

  # Install Python dependencies
  pip install pyyaml torch --extra-index-url https://download.pytorch.org/whl/cpu

  echo "Dependencies installed successfully"
}

# Build a single variant
build_variant() {
  local backends=$1
  local coreml=$2
  local build_type=$3
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-${PLATFORM}-${ARCH}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-${PLATFORM}-${ARCH}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ${PLATFORM}-${ARCH}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}"

  # Get iOS SDK path
  local ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
    -DCMAKE_OSX_SYSROOT="${ios_sdk}" \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    -DEXECUTORCH_VERSION="${VERSION}" \
    -DEXECUTORCH_BUILD_MODE=source \
    -DEXECUTORCH_CACHE_DIR="${CACHE_DIR}" \
    -DET_BUILD_XNNPACK=ON \
    -DET_BUILD_COREML="${coreml}" \
    -DET_BUILD_MPS=OFF \
    -DET_BUILD_VULKAN=OFF \
    -DET_BUILD_QNN=OFF \
    -DCMAKE_INSTALL_PREFIX="${build_dir}/install"

  # Build
  cmake --build "$build_dir" --parallel $(sysctl -n hw.ncpu)

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
  IFS=':' read -r backends coreml <<< "$variant"
  build_variant "$backends" "$coreml" "Release"
  build_variant "$backends" "$coreml" "Debug"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
