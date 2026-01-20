#!/bin/bash
# build-ios.sh - Build all iOS variants (device + simulator)
#
# Builds ALL combinations of backends for iOS:
# Device (arm64):
#   - xnnpack
#   - xnnpack-coreml
#   - xnnpack-vulkan (via MoltenVK)
#   - xnnpack-coreml-vulkan (via MoltenVK)
# Simulator (x86_64 for Intel Macs, arm64 for Apple Silicon):
#   - xnnpack
#   - xnnpack-coreml
#   - xnnpack-vulkan (via MoltenVK)
#   - xnnpack-coreml-vulkan (via MoltenVK)
#
# Vulkan on iOS uses MoltenVK (Vulkan-to-Metal translation layer)
# Vulkan builds require glslc compiler (install: brew install shaderc molten-vk)
#
# Usage: ./build-ios.sh [VERSION]
# Example: ./build-ios.sh 1.0.1

set -e

VERSION="${1:-1.0.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# MoltenVK paths for iOS (set by find_moltenvk_ios)
MOLTENVK_IOS_LIB=""
MOLTENVK_IOS_SIM_LIB=""

# Check for Vulkan SDK / glslc availability (via MoltenVK on iOS/macOS)
check_vulkan() {
    if command -v glslc &> /dev/null; then
        return 0
    elif [ -n "$VULKAN_SDK" ] && [ -x "$VULKAN_SDK/bin/glslc" ]; then
        export PATH="$VULKAN_SDK/bin:$PATH"
        return 0
    fi
    return 1
}

# Find MoltenVK library for iOS from Vulkan SDK (if available)
# Note: iOS typically uses static linking of MoltenVK via ExecuTorch build
find_moltenvk_ios() {
    # Check if VULKAN_SDK is set and has iOS libraries
    if [ -n "$VULKAN_SDK" ]; then
        if [ -f "$VULKAN_SDK/MoltenVK/MoltenVK.xcframework/ios-arm64/libMoltenVK.a" ]; then
            MOLTENVK_IOS_LIB="$VULKAN_SDK/MoltenVK/MoltenVK.xcframework/ios-arm64/libMoltenVK.a"
            echo "  Found iOS device MoltenVK: $MOLTENVK_IOS_LIB"
        fi
        if [ -f "$VULKAN_SDK/MoltenVK/MoltenVK.xcframework/ios-arm64_x86_64-simulator/libMoltenVK.a" ]; then
            MOLTENVK_IOS_SIM_LIB="$VULKAN_SDK/MoltenVK/MoltenVK.xcframework/ios-arm64_x86_64-simulator/libMoltenVK.a"
            echo "  Found iOS simulator MoltenVK: $MOLTENVK_IOS_SIM_LIB"
        fi
    fi

    # iOS MoltenVK is typically linked statically at build time by ExecuTorch
    # The Vulkan backend compiles MoltenVK into the static library
    return 0
}

# All iOS variants: combinations of coreml and vulkan
# Format: backends:coreml:vulkan
# Define all variants - if Vulkan variant is listed and SDK is missing, build will fail
VARIANTS=(
  "xnnpack:OFF:OFF"
  "xnnpack-coreml:ON:OFF"
  "xnnpack-vulkan:OFF:ON"
  "xnnpack-coreml-vulkan:ON:ON"
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
  local vulkan=$3
  local build_type=$4
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local arch="arm64"
  local build_dir="${PROJECT_DIR}/build-ios-${arch}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-ios-${arch}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ios-${arch}-${backends}-${build_type_lower} (device) ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}, Vulkan=${vulkan}"

  # Check Vulkan requirement
  if [ "$vulkan" = "ON" ]; then
    if ! check_vulkan; then
      echo "ERROR: Vulkan variant requested but glslc not found"
      echo "Please install: brew install shaderc molten-vk"
      exit 1
    fi
    echo "  Vulkan: enabled (glslc found)"
  fi

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
    -DET_BUILD_VULKAN="${vulkan}" \
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
  local vulkan=$3
  local build_type=$4
  local arch=$5  # x86_64 or arm64
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-ios-simulator-${arch}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-ios-simulator-${arch}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ios-simulator-${arch}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}, Vulkan=${vulkan}"

  # Check Vulkan requirement
  if [ "$vulkan" = "ON" ]; then
    if ! check_vulkan; then
      echo "ERROR: Vulkan variant requested but glslc not found"
      echo "Please install: brew install shaderc molten-vk"
      exit 1
    fi
    echo "  Vulkan: enabled (glslc found)"
  fi

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
    -DET_BUILD_VULKAN="${vulkan}" \
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
  IFS=':' read -r backends coreml vulkan <<< "$variant"
  build_device_variant "$backends" "$coreml" "$vulkan" "Release"
  build_device_variant "$backends" "$coreml" "$vulkan" "Debug"
done

# Build all simulator variants (x86_64 for Intel Macs)
echo ""
echo "============================================================"
echo "Building iOS Simulator variants (x86_64)"
echo "============================================================"
for variant in "${VARIANTS[@]}"; do
  IFS=':' read -r backends coreml vulkan <<< "$variant"
  build_simulator_variant "$backends" "$coreml" "$vulkan" "Release" "x86_64"
  build_simulator_variant "$backends" "$coreml" "$vulkan" "Debug" "x86_64"
done

# Build all simulator variants (arm64 for Apple Silicon)
echo ""
echo "============================================================"
echo "Building iOS Simulator variants (arm64)"
echo "============================================================"
for variant in "${VARIANTS[@]}"; do
  IFS=':' read -r backends coreml vulkan <<< "$variant"
  build_simulator_variant "$backends" "$coreml" "$vulkan" "Release" "arm64"
  build_simulator_variant "$backends" "$coreml" "$vulkan" "Debug" "arm64"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
