#!/bin/bash
# build-android.sh - Build all Android variants
#
# Builds ALL combinations of backends for Android:
# - arm64-v8a: xnnpack, xnnpack-vulkan (64-bit ARM devices)
# - armeabi-v7a: xnnpack, xnnpack-vulkan (32-bit ARM devices)
# - x86_64: xnnpack, xnnpack-vulkan (64-bit emulator)
# - x86: xnnpack, xnnpack-vulkan (32-bit emulator)
#
# Vulkan builds require glslc compiler (from Android NDK or Vulkan SDK)
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

# Android ABIs to build (all supported architectures)
ABIS=(
  "arm64-v8a"
  "armeabi-v7a"
  "x86_64"
  "x86"
)

# Check for glslc availability (needed for Vulkan shader compilation)
# Android NDK r21+ includes glslc in the shader-tools directory
check_vulkan() {
    if command -v glslc &> /dev/null; then
        return 0
    elif [ -n "$ANDROID_NDK_HOME" ]; then
        # Try to find glslc in NDK (different locations depending on NDK version)
        for glslc_path in \
            "$ANDROID_NDK_HOME/shader-tools/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/glslc" \
            "$ANDROID_NDK_HOME/shader-tools/linux-x86_64/glslc" \
            "$ANDROID_NDK_HOME/shader-tools/darwin-x86_64/glslc" \
            "$ANDROID_NDK_HOME/shader-tools/windows-x86_64/glslc.exe"; do
            if [ -x "$glslc_path" ]; then
                export PATH="$(dirname "$glslc_path"):$PATH"
                return 0
            fi
        done
    fi
    if [ -n "$VULKAN_SDK" ] && [ -x "$VULKAN_SDK/bin/glslc" ]; then
        export PATH="$VULKAN_SDK/bin:$PATH"
        return 0
    fi
    return 1
}

# All variants to build: backends:vulkan
# Define all variants - if Vulkan variant is listed and SDK is missing, build will fail
VARIANTS=(
    "xnnpack:OFF"
    "xnnpack-vulkan:ON"
)

echo "============================================================"
echo "ExecuTorch Android Build Script"
echo "============================================================"
echo "  Version: ${VERSION}"
echo "  Platform: ${PLATFORM}"
echo "  ABIs: ${ABIS[*]}"
echo "  Variants: ${#VARIANTS[@]}"
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
  local backends=$2
  local vulkan=$3
  local build_type=$4
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-${PLATFORM}-${abi}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-${PLATFORM}-${abi}-${backends}-${build_type_lower}.tar.gz"

  echo ""
  echo "=== Building ${PLATFORM}-${abi}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, Vulkan=${vulkan}"

  # Check Vulkan requirement
  if [ "$vulkan" = "ON" ]; then
    if ! check_vulkan; then
      echo "ERROR: Vulkan variant requested but glslc not found"
      echo "Please install the Vulkan SDK or use Android NDK r21+ which includes glslc"
      exit 1
    fi
    echo "  Vulkan: enabled (glslc found)"
  fi

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
    -DET_BUILD_VULKAN="${vulkan}" \
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

# Build all ABI and variant combinations
for abi in "${ABIS[@]}"; do
  echo ""
  echo "============================================================"
  echo "Building ${abi} variants"
  echo "============================================================"

  for variant in "${VARIANTS[@]}"; do
    IFS=':' read -r backends vulkan <<< "$variant"
    build_variant "$abi" "$backends" "$vulkan" "Release"
    build_variant "$abi" "$backends" "$vulkan" "Debug"
  done
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
