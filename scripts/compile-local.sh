#!/bin/bash
# compile-local.sh - Build executorch_ffi from LOCAL ExecuTorch source
#
# This script compiles the executorch_ffi library from a local ExecuTorch
# source directory. The output is placed in native/local-builds/ so that
# the Flutter plugin's build_mode: "local" can auto-detect it.
#
# Usage:
#   ./compile-local.sh --executorch-source /path/to/executorch [options]
#
# Examples:
#   # Build for Android arm64 with Vulkan (from macOS)
#   ./compile-local.sh \
#     --executorch-source ~/executorch \
#     --platform android \
#     --arch arm64-v8a \
#     --backends xnnpack,vulkan
#
#   # Build for current host (macOS/Linux)
#   ./compile-local.sh --executorch-source ~/executorch
#
#   # Build for Android with custom NDK path
#   ./compile-local.sh \
#     --executorch-source ~/executorch \
#     --platform android \
#     --arch arm64-v8a \
#     --ndk ~/Android/Sdk/ndk/27.0.12077973
#
# Output: native/local-builds/<platform>-<arch>-<backends>-<build_type>/
#   ├── lib/         # Compiled shared libraries
#   └── include/     # Header files

set -e

# ============================================================================
# Default Configuration
# ============================================================================

EXECUTORCH_SOURCE=""
PLATFORM=""
ARCH=""
BACKENDS="xnnpack"
BUILD_TYPE="Release"
NDK_PATH="${ANDROID_NDK_HOME:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Parse Arguments
# ============================================================================

print_usage() {
    echo "Usage: $0 --executorch-source <path> [options]"
    echo ""
    echo "Required:"
    echo "  --executorch-source <path>  Path to local ExecuTorch source"
    echo ""
    echo "Options:"
    echo "  --platform <name>    Target: android, macos, linux, windows"
    echo "                       Default: auto-detect host platform"
    echo "  --arch <name>        Architecture:"
    echo "                         android: arm64-v8a, armeabi-v7a, x86_64, x86"
    echo "                         macos: arm64, x64"
    echo "                         linux: arm64, x64"
    echo "                       Default: auto-detect"
    echo "  --backends <list>    Comma-separated: xnnpack,vulkan,coreml,mps"
    echo "                       Default: xnnpack"
    echo "  --build-type <type>  Release or Debug (default: Release)"
    echo "  --ndk <path>         Android NDK path (or set ANDROID_NDK_HOME)"
    echo "  --help               Show this help"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --executorch-source)
            EXECUTORCH_SOURCE="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --backends)
            BACKENDS="$2"
            shift 2
            ;;
        --build-type)
            BUILD_TYPE="$2"
            shift 2
            ;;
        --ndk)
            NDK_PATH="$2"
            shift 2
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# ============================================================================
# Validate Arguments
# ============================================================================

if [ -z "$EXECUTORCH_SOURCE" ]; then
    echo "ERROR: --executorch-source is required"
    echo ""
    print_usage
    exit 1
fi

# Resolve to absolute path
EXECUTORCH_SOURCE="$(cd "$EXECUTORCH_SOURCE" && pwd)"

if [ ! -f "$EXECUTORCH_SOURCE/CMakeLists.txt" ]; then
    echo "ERROR: Not a valid ExecuTorch source directory: $EXECUTORCH_SOURCE"
    echo "  Missing CMakeLists.txt"
    exit 1
fi

# Auto-detect platform
if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Darwin) PLATFORM="macos" ;;
        Linux)  PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) echo "ERROR: Cannot auto-detect platform"; exit 1 ;;
    esac
fi

# Auto-detect architecture
if [ -z "$ARCH" ]; then
    case "$PLATFORM" in
        android)
            ARCH="arm64-v8a"  # Most common Android target
            ;;
        macos)
            case "$(uname -m)" in
                arm64) ARCH="arm64" ;;
                *)     ARCH="x64" ;;
            esac
            ;;
        linux)
            case "$(uname -m)" in
                aarch64|arm64) ARCH="arm64" ;;
                *)             ARCH="x64" ;;
            esac
            ;;
        windows)
            ARCH="x64"
            ;;
    esac
fi

# Validate Android NDK
if [ "$PLATFORM" = "android" ]; then
    if [ -z "$NDK_PATH" ]; then
        echo "ERROR: Android NDK path required"
        echo "  Set --ndk <path> or ANDROID_NDK_HOME environment variable"
        exit 1
    fi
    if [ ! -f "$NDK_PATH/build/cmake/android.toolchain.cmake" ]; then
        echo "ERROR: Android toolchain not found at $NDK_PATH"
        exit 1
    fi
fi

# ============================================================================
# Build Configuration
# ============================================================================

# Parse backends into CMake flags
ET_XNNPACK="OFF"
ET_VULKAN="OFF"
ET_COREML="OFF"
ET_MPS="OFF"

IFS=',' read -ra BACKEND_LIST <<< "$BACKENDS"
for backend in "${BACKEND_LIST[@]}"; do
    case "$backend" in
        xnnpack) ET_XNNPACK="ON" ;;
        vulkan)  ET_VULKAN="ON" ;;
        coreml)  ET_COREML="ON" ;;
        mps)     ET_MPS="ON" ;;
        *) echo "WARNING: Unknown backend: $backend" ;;
    esac
done

# Build variant string (matches prebuilt naming)
VARIANT=$(echo "$BACKENDS" | tr ',' '-')
BUILD_TYPE_LOWER=$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')

# Output directory
OUTPUT_DIR="${PROJECT_DIR}/local-builds/${PLATFORM}-${ARCH}-${VARIANT}-${BUILD_TYPE_LOWER}"
BUILD_DIR="${PROJECT_DIR}/build-local-${PLATFORM}-${ARCH}-${VARIANT}-${BUILD_TYPE_LOWER}"

# ExecuTorch cache dir = parent of executorch source
# build_from_source.cmake expects CACHE_DIR/executorch/
CACHE_DIR="$(dirname "$EXECUTORCH_SOURCE")"

echo "============================================================"
echo "ExecuTorch Local Build"
echo "============================================================"
echo "  ExecuTorch source: ${EXECUTORCH_SOURCE}"
echo "  Platform:          ${PLATFORM}"
echo "  Architecture:      ${ARCH}"
echo "  Backends:          ${BACKENDS}"
echo "  Build type:        ${BUILD_TYPE}"
echo "  Variant:           ${VARIANT}"
echo "  Output:            ${OUTPUT_DIR}"
echo "  Build dir:         ${BUILD_DIR}"
if [ "$PLATFORM" = "android" ]; then
    echo "  NDK:               ${NDK_PATH}"
fi
echo "============================================================"

# Check for Vulkan requirements
if [ "$ET_VULKAN" = "ON" ]; then
    GLSLC_FOUND=false
    if [ -n "$VULKAN_SDK" ] && [ -x "$VULKAN_SDK/bin/glslc" ]; then
        export PATH="$VULKAN_SDK/bin:$PATH"
        echo "  Vulkan SDK glslc: $VULKAN_SDK/bin/glslc"
        GLSLC_FOUND=true
    elif command -v glslc &> /dev/null; then
        echo "  System glslc: $(which glslc)"
        GLSLC_FOUND=true
    elif [ "$PLATFORM" = "android" ] && [ -n "$NDK_PATH" ]; then
        # Try NDK shader tools
        HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        NDK_GLSLC="$NDK_PATH/shader-tools/${HOST_OS}-x86_64/glslc"
        if [ -x "$NDK_GLSLC" ]; then
            export PATH="$(dirname "$NDK_GLSLC"):$PATH"
            echo "  NDK glslc: $NDK_GLSLC"
            echo "  WARNING: NDK glslc may lack GL_EXT_integer_dot_product"
            GLSLC_FOUND=true
        fi
    fi

    if [ "$GLSLC_FOUND" = false ]; then
        echo "ERROR: Vulkan backend requires glslc compiler"
        echo "  Install Vulkan SDK: https://vulkan.lunarg.com/"
        echo "  Or set VULKAN_SDK environment variable"
        exit 1
    fi
fi

# ============================================================================
# Build
# ============================================================================

echo ""
echo "Configuring..."

# Platform-specific CMake args
CMAKE_EXTRA_ARGS=""
if [ "$PLATFORM" = "android" ]; then
    CMAKE_EXTRA_ARGS="-DCMAKE_TOOLCHAIN_FILE=$NDK_PATH/build/cmake/android.toolchain.cmake"
    CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DANDROID_ABI=$ARCH"
    CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DANDROID_PLATFORM=android-23"
    CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DANDROID_STL=c++_shared"
elif [ "$PLATFORM" = "macos" ]; then
    CMAKE_EXTRA_ARGS="-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"
    if [ "$ARCH" = "arm64" ]; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DCMAKE_OSX_ARCHITECTURES=arm64"
    else
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DCMAKE_OSX_ARCHITECTURES=x86_64"
    fi
fi

# Detect build tool
GENERATOR_ARGS=""
if command -v ninja &> /dev/null; then
    GENERATOR_ARGS="-G Ninja"
    echo "  Using Ninja generator"
else
    echo "  Using default CMake generator (install ninja for faster builds)"
fi

# Configure
cmake -B "$BUILD_DIR" -S "$PROJECT_DIR" \
    $GENERATOR_ARGS \
    $CMAKE_EXTRA_ARGS \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DEXECUTORCH_BUILD_MODE=source \
    -DEXECUTORCH_CACHE_DIR="$CACHE_DIR" \
    -DET_BUILD_XNNPACK="$ET_XNNPACK" \
    -DET_BUILD_COREML="$ET_COREML" \
    -DET_BUILD_MPS="$ET_MPS" \
    -DET_BUILD_VULKAN="$ET_VULKAN" \
    -DET_BUILD_QNN=OFF \
    -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR"

# Build
echo ""
echo "Building..."

# Detect parallel job count
if command -v nproc &> /dev/null; then
    JOBS=$(nproc)
elif command -v sysctl &> /dev/null; then
    JOBS=$(sysctl -n hw.ncpu)
else
    JOBS=4
fi

cmake --build "$BUILD_DIR" --parallel "$JOBS"

# Install
echo ""
echo "Installing to ${OUTPUT_DIR}..."
cmake --install "$BUILD_DIR"

# ============================================================================
# Verify Output
# ============================================================================

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo ""
echo "Output directory: ${OUTPUT_DIR}"
echo ""

if [ -d "$OUTPUT_DIR/lib" ]; then
    echo "Libraries:"
    ls -la "$OUTPUT_DIR/lib/"
else
    echo "WARNING: lib/ directory not created"
fi

echo ""
if [ -d "$OUTPUT_DIR/include" ]; then
    echo "Headers:"
    ls -la "$OUTPUT_DIR/include/"
else
    echo "WARNING: include/ directory not created"
fi

echo ""
echo "============================================================"
echo "To use with Flutter, set in your app's pubspec.yaml:"
echo ""
echo "  hooks:"
echo "    user_defines:"
echo "      executorch_flutter:"
echo "        build_mode: \"local\""
echo "        local_lib_dir: \"${OUTPUT_DIR}\""
echo "        backends:"
for backend in "${BACKEND_LIST[@]}"; do
    echo "          - $backend"
done
echo ""
echo "Or auto-detect (if building from the native/ directory):"
echo ""
echo "  hooks:"
echo "    user_defines:"
echo "      executorch_flutter:"
echo "        build_mode: \"local\""
echo "        backends:"
for backend in "${BACKEND_LIST[@]}"; do
    echo "          - $backend"
done
echo "============================================================"
