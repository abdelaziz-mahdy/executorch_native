#!/bin/bash
# build-linux.sh - Build all Linux x64 variants
#
# Builds ALL combinations of backends for Linux x64:
# - xnnpack
# - xnnpack-vulkan
#
# Usage: ./build-linux.sh [VERSION]
# Example: ./build-linux.sh 1.0.1

set -e

VERSION="${1:-1.0.1}"
ARCH="x64"
PLATFORM="linux"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# All variants to build: backends:vulkan
VARIANTS=(
  "xnnpack:OFF"
  "xnnpack-vulkan:ON"
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

  # Install Vulkan SDK
  echo "Installing Vulkan SDK..."
  wget -qO - https://packages.lunarg.com/lunarg-signing-key-pub.asc | sudo apt-key add -
  sudo wget -qO /etc/apt/sources.list.d/lunarg-vulkan-jammy.list https://packages.lunarg.com/vulkan/lunarg-vulkan-jammy.list
  sudo apt-get update
  sudo apt-get install -y vulkan-sdk

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
