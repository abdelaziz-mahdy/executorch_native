#!/bin/bash
# build-android.sh - Build all Android variants (arm64-v8a + x86_64)
#
# Builds ALL combinations of backends for Android:
# - arm64-v8a: xnnpack
# - x86_64: xnnpack (for emulator)
#
# Usage: ./build-android.sh [VERSION]
# Example: ./build-android.sh 1.0.1
#
# Requires: ANDROID_NDK_HOME environment variable

set -e

VERSION="${1:-1.0.1}"
PLATFORM="android"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# Android ABIs to build
ABIS=(
  "arm64-v8a"
  "x86_64"
)

# Backends (currently only xnnpack for Android)
BACKENDS="xnnpack"

echo "============================================================"
echo "ExecuTorch Android Build Script"
echo "============================================================"
echo "  Version: ${VERSION}"
echo "  Platform: ${PLATFORM}"
echo "  ABIs: ${ABIS[*]}"
echo "  Backends: ${BACKENDS}"
echo "  NDK: ${ANDROID_NDK_HOME:-NOT SET}"
echo "============================================================"

# Check NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
  echo "ERROR: ANDROID_NDK_HOME environment variable is not set"
  echo "Please set it to your Android NDK installation path"
  exit 1
fi

if [ ! -f "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" ]; then
  echo "ERROR: Android toolchain not found at $ANDROID_NDK_HOME"
  exit 1
fi

# Install dependencies
install_dependencies() {
  echo ""
  echo "=== Installing dependencies ==="

  sudo apt-get update
  sudo apt-get install -y ninja-build

  # Install Python dependencies
  pip install pyyaml torch --extra-index-url https://download.pytorch.org/whl/cpu

  echo "Dependencies installed successfully"
}

# Build a single variant
build_variant() {
  local abi=$1
  local build_type=$2
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-${PLATFORM}-${abi}-${BACKENDS}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-${PLATFORM}-${abi}-${BACKENDS}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ${PLATFORM}-${abi}-${BACKENDS}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${abi}" \
    -DANDROID_PLATFORM=android-23 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    -DEXECUTORCH_VERSION="${VERSION}" \
    -DEXECUTORCH_BUILD_MODE=source \
    -DEXECUTORCH_CACHE_DIR="${CACHE_DIR}" \
    -DET_BUILD_XNNPACK=ON \
    -DET_BUILD_COREML=OFF \
    -DET_BUILD_MPS=OFF \
    -DET_BUILD_VULKAN=OFF \
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

# Build all ABI variants
for abi in "${ABIS[@]}"; do
  echo ""
  echo "============================================================"
  echo "Building ${abi} variants"
  echo "============================================================"
  build_variant "$abi" "Release"
  build_variant "$abi" "Debug"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
