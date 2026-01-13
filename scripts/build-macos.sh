#!/bin/bash
# build-macos.sh - Build all macOS variants (arm64 + x86_64)
#
# Builds ALL combinations of backends for macOS:
# - arm64: 8 combinations (2^3 = coreml × mps × vulkan)
# - x86_64: 4 combinations (2^2 = coreml × vulkan, no MPS)
#
# Usage: ./build-macos.sh [VERSION]
# Example: ./build-macos.sh 1.0.1

set -e

VERSION="${1:-1.0.1}"
PLATFORM="macos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# arm64: combinations of coreml/mps (Vulkan disabled - requires glslc compiler setup)
# Format: backends:coreml:mps:vulkan
ARM64_VARIANTS=(
  "xnnpack:OFF:OFF:OFF"
  "xnnpack-coreml:ON:OFF:OFF"
  "xnnpack-mps:OFF:ON:OFF"
  "xnnpack-coreml-mps:ON:ON:OFF"
  # Vulkan variants disabled - TODO: Enable once Vulkan build is properly configured
  # "xnnpack-vulkan:OFF:OFF:ON"
  # "xnnpack-coreml-vulkan:ON:OFF:ON"
  # "xnnpack-mps-vulkan:OFF:ON:ON"
  # "xnnpack-coreml-mps-vulkan:ON:ON:ON"
)

# x86_64: coreml only (no MPS on Intel, Vulkan disabled)
# Format: backends:coreml:vulkan
X64_VARIANTS=(
  "xnnpack:OFF:OFF"
  "xnnpack-coreml:ON:OFF"
  # Vulkan variants disabled - TODO: Enable once Vulkan build is properly configured
  # "xnnpack-vulkan:OFF:ON"
  # "xnnpack-coreml-vulkan:ON:ON"
)

echo "============================================================"
echo "ExecuTorch macOS Build Script"
echo "============================================================"
echo "  Version: ${VERSION}"
echo "  Platform: ${PLATFORM}"
echo "  arm64 variants: ${#ARM64_VARIANTS[@]}"
echo "  x86_64 variants: ${#X64_VARIANTS[@]}"
echo "  Total builds: $(( (${#ARM64_VARIANTS[@]} + ${#X64_VARIANTS[@]}) * 2 ))"
echo "============================================================"

# Install dependencies
install_dependencies() {
  echo ""
  echo "=== Installing dependencies ==="

  # Install Python dependencies
  pip install pyyaml torch --extra-index-url https://download.pytorch.org/whl/cpu

  # Install Vulkan support via MoltenVK
  echo "Installing MoltenVK for Vulkan support..."
  brew install molten-vk || true

  echo "Dependencies installed successfully"
}

# Build a single variant
build_variant() {
  local arch=$1
  local backends=$2
  local coreml=$3
  local mps=$4
  local vulkan=$5
  local build_type=$6
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-${PLATFORM}-${arch}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-${PLATFORM}-${arch}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ${PLATFORM}-${arch}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}, MPS=${mps}, Vulkan=${vulkan}"

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DEXECUTORCH_VERSION="${VERSION}" \
    -DEXECUTORCH_BUILD_MODE=source \
    -DEXECUTORCH_CACHE_DIR="${CACHE_DIR}" \
    -DET_BUILD_XNNPACK=ON \
    -DET_BUILD_COREML="${coreml}" \
    -DET_BUILD_MPS="${mps}" \
    -DET_BUILD_VULKAN="${vulkan}" \
    -DET_BUILD_QNN=OFF \
    -DCMAKE_INSTALL_PREFIX="${build_dir}/install"

  # Build
  cmake --build "$build_dir" --config "${build_type}" --parallel $(sysctl -n hw.ncpu)

  # Install
  cmake --install "$build_dir" --config "${build_type}"

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

# Build all arm64 variants
echo ""
echo "============================================================"
echo "Building arm64 variants (${#ARM64_VARIANTS[@]} combinations)"
echo "============================================================"
for variant in "${ARM64_VARIANTS[@]}"; do
  IFS=':' read -r backends coreml mps vulkan <<< "$variant"
  build_variant "arm64" "$backends" "$coreml" "$mps" "$vulkan" "Release"
  build_variant "arm64" "$backends" "$coreml" "$mps" "$vulkan" "Debug"
done

# Build all x86_64 variants (cross-compile on arm64 runner)
echo ""
echo "============================================================"
echo "Building x86_64 variants (${#X64_VARIANTS[@]} combinations)"
echo "============================================================"
for variant in "${X64_VARIANTS[@]}"; do
  IFS=':' read -r backends coreml vulkan <<< "$variant"
  build_variant "x86_64" "$backends" "$coreml" "OFF" "$vulkan" "Release"
  build_variant "x86_64" "$backends" "$coreml" "OFF" "$vulkan" "Debug"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
