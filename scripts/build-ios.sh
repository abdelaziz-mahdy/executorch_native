#!/bin/bash
# build-ios.sh - Build all iOS variants (device + simulator)
#
# Builds ALL combinations of backends for iOS:
# Device (arm64):
#   - xnnpack
#   - xnnpack-coreml
# Simulator (x86_64 for Intel Macs, arm64 for Apple Silicon):
#   - xnnpack
#   - xnnpack-coreml
#
# Usage: ./build-ios.sh [VERSION]
# Example: ./build-ios.sh 1.0.1

set -e

VERSION="${1:-1.0.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# iOS variants: all combinations of coreml
# Format: backends:coreml
VARIANTS=(
  "xnnpack:OFF"
  "xnnpack-coreml:ON"
)

echo "============================================================"
echo "ExecuTorch iOS Build Script"
echo "============================================================"
echo "  Version: ${VERSION}"
echo "  Variants: ${#VARIANTS[@]}"
echo "  Targets: device (arm64), simulator (x86_64, arm64)"
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

# Build a single variant for device (arm64)
build_device_variant() {
  local backends=$1
  local coreml=$2
  local build_type=$3
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local arch="arm64"
  local build_dir="${PROJECT_DIR}/build-ios-${arch}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-ios-${arch}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ios-${arch}-${backends}-${build_type_lower} (device) ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}"

  # Get iOS SDK path
  local ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
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

# Build a single variant for simulator
build_simulator_variant() {
  local backends=$1
  local coreml=$2
  local build_type=$3
  local arch=$4  # x86_64 or arm64
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-ios-simulator-${arch}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-ios-simulator-${arch}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ios-simulator-${arch}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}"

  # Get iOS Simulator SDK path
  local sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_SYSROOT="${sim_sdk}" \
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

# Build all device variants (arm64)
echo ""
echo "============================================================"
echo "Building iOS Device variants (arm64)"
echo "============================================================"
for variant in "${VARIANTS[@]}"; do
  IFS=':' read -r backends coreml <<< "$variant"
  build_device_variant "$backends" "$coreml" "Release"
  build_device_variant "$backends" "$coreml" "Debug"
done

# Build all simulator variants (x86_64 for Intel Macs)
echo ""
echo "============================================================"
echo "Building iOS Simulator variants (x86_64)"
echo "============================================================"
for variant in "${VARIANTS[@]}"; do
  IFS=':' read -r backends coreml <<< "$variant"
  build_simulator_variant "$backends" "$coreml" "Release" "x86_64"
  build_simulator_variant "$backends" "$coreml" "Debug" "x86_64"
done

# Build all simulator variants (arm64 for Apple Silicon)
echo ""
echo "============================================================"
echo "Building iOS Simulator variants (arm64)"
echo "============================================================"
for variant in "${VARIANTS[@]}"; do
  IFS=':' read -r backends coreml <<< "$variant"
  build_simulator_variant "$backends" "$coreml" "Release" "arm64"
  build_simulator_variant "$backends" "$coreml" "Debug" "arm64"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
