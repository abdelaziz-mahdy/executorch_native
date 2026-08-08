#!/bin/bash
# build-macos.sh - Build all macOS variants (arm64 + x86_64)
#
# Builds ALL combinations of backends for macOS:
# - arm64: coreml × metal combinations, plus Vulkan variants if MoltenVK available
# - x86_64: coreml combinations, plus Vulkan variants if MoltenVK available
#
# The Metal backend (AOTI-based, macOS-desktop GPU) replaces the deprecated MPS
# backend and is built for arm64 only. libomp (its OpenMP runtime) is bundled
# with Metal variants for runtime use.
# Vulkan on macOS uses MoltenVK (Vulkan-to-Metal translation layer)
# MoltenVK is bundled with Vulkan variants for runtime use.
#
# Usage: ./build-macos.sh [VERSION]
# Example: ./build-macos.sh 1.4.0

set -e

VERSION="${1:-1.4.0}"
PLATFORM="macos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${PROJECT_DIR}/.cache"

# MoltenVK paths (set by find_moltenvk after brew install)
MOLTENVK_LIB=""
MOLTENVK_ICD=""

# Check for Vulkan SDK / glslc availability (via MoltenVK on macOS)
check_vulkan() {
    if command -v glslc &> /dev/null; then
        return 0
    elif [ -n "$VULKAN_SDK" ] && [ -x "$VULKAN_SDK/bin/glslc" ]; then
        export PATH="$VULKAN_SDK/bin:$PATH"
        return 0
    fi
    return 1
}

# Find MoltenVK library and ICD JSON from Homebrew installation
find_moltenvk() {
    local brew_prefix
    brew_prefix=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")

    # Look for libMoltenVK.dylib
    if [ -f "${brew_prefix}/lib/libMoltenVK.dylib" ]; then
        MOLTENVK_LIB="${brew_prefix}/lib/libMoltenVK.dylib"
    elif [ -f "/usr/local/lib/libMoltenVK.dylib" ]; then
        MOLTENVK_LIB="/usr/local/lib/libMoltenVK.dylib"
    fi

    # Look for MoltenVK_icd.json (can be in share/ or etc/ depending on version)
    if [ -f "${brew_prefix}/share/vulkan/icd.d/MoltenVK_icd.json" ]; then
        MOLTENVK_ICD="${brew_prefix}/share/vulkan/icd.d/MoltenVK_icd.json"
    elif [ -f "${brew_prefix}/etc/vulkan/icd.d/MoltenVK_icd.json" ]; then
        MOLTENVK_ICD="${brew_prefix}/etc/vulkan/icd.d/MoltenVK_icd.json"
    elif [ -f "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json" ]; then
        MOLTENVK_ICD="/usr/local/share/vulkan/icd.d/MoltenVK_icd.json"
    elif [ -f "/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json" ]; then
        MOLTENVK_ICD="/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json"
    fi

    if [ -n "$MOLTENVK_LIB" ] && [ -n "$MOLTENVK_ICD" ]; then
        echo "  Found MoltenVK library: $MOLTENVK_LIB"
        echo "  Found MoltenVK ICD: $MOLTENVK_ICD"
        return 0
    fi
    return 1
}

# Bundle MoltenVK files into the install directory for Vulkan variants
bundle_moltenvk() {
    local install_dir=$1

    if [ -z "$MOLTENVK_LIB" ] || [ -z "$MOLTENVK_ICD" ]; then
        echo "  WARNING: MoltenVK not found, skipping bundle"
        return 1
    fi

    echo "  Bundling MoltenVK runtime files..."

    # Create directories
    mkdir -p "${install_dir}/lib"
    mkdir -p "${install_dir}/share/vulkan/icd.d"

    # Copy libMoltenVK.dylib
    cp "$MOLTENVK_LIB" "${install_dir}/lib/"
    echo "    Copied libMoltenVK.dylib"

    # Fix MoltenVK install name to use @rpath for relocatability
    local moltenvk_dest="${install_dir}/lib/libMoltenVK.dylib"
    install_name_tool -id "@rpath/libMoltenVK.dylib" "$moltenvk_dest" 2>/dev/null || true
    echo "    Fixed MoltenVK install name to @rpath"

    # Add @loader_path to rpath of executorch_ffi library so it finds MoltenVK
    # The FFI library should be able to find MoltenVK in the same directory
    local ffi_lib="${install_dir}/lib/libexecutorch_ffi.dylib"
    if [ -f "$ffi_lib" ]; then
        # Add @loader_path to rpath (where the loader itself is located)
        install_name_tool -add_rpath "@loader_path" "$ffi_lib" 2>/dev/null || true
        echo "    Added @loader_path to FFI library rpath"
    fi

    # Create modified ICD JSON with relative path
    # The JSON points the loader to the library location
    cat > "${install_dir}/share/vulkan/icd.d/MoltenVK_icd.json" << 'ICDJSON'
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "../../../lib/libMoltenVK.dylib",
        "api_version" : "1.2.0"
    }
}
ICDJSON
    echo "    Created MoltenVK_icd.json with relative path"

    return 0
}

# Bundle libomp (the OpenMP runtime the Metal/AOTI backend links) into the
# install directory and rewrite the FFI library to load it via @rpath, so the
# prebuilt is relocatable (the build otherwise links an absolute libomp path).
bundle_libomp() {
    local install_dir=$1
    local ffi_lib="${install_dir}/lib/libexecutorch_ffi.dylib"
    [ -f "$ffi_lib" ] || return 0

    # Path the FFI library currently references for libomp
    local omp_ref
    omp_ref=$(otool -L "$ffi_lib" | awk '/libomp\.dylib/ {print $1; exit}')
    if [ -z "$omp_ref" ]; then
        echo "  No libomp dependency in FFI library (skipping libomp bundle)"
        return 0
    fi

    # Resolve the libomp file on disk (the referenced path, or common fallbacks)
    local omp_src=""
    if [ -f "$omp_ref" ]; then
        omp_src="$omp_ref"
    else
        for cand in \
            "$(python3 -c 'import os,torch;print(os.path.join(os.path.dirname(torch.__file__),"lib","libomp.dylib"))' 2>/dev/null)" \
            "$(brew --prefix libomp 2>/dev/null)/lib/libomp.dylib" \
            /opt/homebrew/lib/libomp.dylib \
            /usr/local/lib/libomp.dylib; do
            if [ -n "$cand" ] && [ -f "$cand" ]; then omp_src="$cand"; break; fi
        done
    fi
    if [ -z "$omp_src" ]; then
        echo "  WARNING: could not locate libomp ($omp_ref) to bundle"
        return 1
    fi

    echo "  Bundling libomp for Metal variant..."
    mkdir -p "${install_dir}/lib"
    cp "$omp_src" "${install_dir}/lib/libomp.dylib"
    install_name_tool -id "@rpath/libomp.dylib" "${install_dir}/lib/libomp.dylib" 2>/dev/null || true
    install_name_tool -change "$omp_ref" "@rpath/libomp.dylib" "$ffi_lib" 2>/dev/null || true
    # Ensure the FFI library searches its own directory for the bundled libomp
    install_name_tool -add_rpath "@loader_path" "$ffi_lib" 2>/dev/null || true
    echo "    Bundled libomp.dylib and repointed FFI to @rpath/libomp.dylib"
    return 0
}

# arm64: combinations of coreml/metal/vulkan
# Format: backends:coreml:metal:vulkan
ARM64_VARIANTS=(
  "xnnpack:OFF:OFF:OFF"
  "xnnpack-coreml:ON:OFF:OFF"
  "xnnpack-metal:OFF:ON:OFF"
  "xnnpack-coreml-metal:ON:ON:OFF"
  "xnnpack-vulkan:OFF:OFF:ON"
  "xnnpack-coreml-vulkan:ON:OFF:ON"
  "xnnpack-metal-vulkan:OFF:ON:ON"
  "xnnpack-coreml-metal-vulkan:ON:ON:ON"
)

# x86_64: coreml only (no MPS on Intel)
# Format: backends:coreml:vulkan
X64_VARIANTS=(
  "xnnpack:OFF:OFF"
  "xnnpack-coreml:ON:OFF"
  "xnnpack-vulkan:OFF:ON"
  "xnnpack-coreml-vulkan:ON:ON"
)

# LLM (text generation) variants — separate from the tensor-only variants above
# so vision builds don't carry the runner/tokenizers. The variant name MUST match
# the suffix EXECUTORCH_VARIANT computes (xnnpack + [mlx] + llm), so the package's
# prebuilt download resolves. Format: name:coreml:metal:vulkan:mlx:llm
#  - xnnpack-llm     : CPU LLM (works on any arch)
#  - xnnpack-mlx-llm : Apple-Silicon GPU LLM (arm64 only; bundles mlx.metallib)
ARM64_LLM_VARIANTS=(
  "xnnpack-llm:OFF:OFF:OFF:OFF:ON"
  "xnnpack-mlx-llm:OFF:OFF:OFF:ON:ON"
)
X64_LLM_VARIANTS=(
  "xnnpack-llm:OFF:OFF:OFF:OFF:ON"
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

  # Install Python dependencies.
  # The Metal backend is AOTI-based and compiles against PyTorch's AOTInductor
  # headers, so torch must match the version ExecuTorch pins (2.11.x for the
  # 1.3.x series). Keep this in sync with ExecuTorch's install_requirements.
  pip install pyyaml "torch==2.11.*" --extra-index-url https://download.pytorch.org/whl/cpu

  # Find MoltenVK installation (installed via Homebrew in CI)
  echo "Looking for MoltenVK..."
  if find_moltenvk; then
    echo "MoltenVK found - will be bundled with Vulkan variants"
  else
    echo "WARNING: MoltenVK not found - Vulkan variants will not include runtime"
    echo "         Install with: brew install molten-vk"
  fi

  # The MLX LLM variant compiles Metal shaders (mlx.metallib) with the `metal`
  # tool, which Xcode 15+/26 ships as a separate downloadable component. Install
  # it so the xnnpack-mlx-llm build doesn't fail with "cannot execute tool 'metal'".
  echo "Ensuring Xcode Metal Toolchain is installed (for the MLX LLM variant)..."
  xcodebuild -downloadComponent MetalToolchain 2>/dev/null || \
    echo "WARNING: could not download Metal Toolchain; xnnpack-mlx-llm may fail."

  echo "Dependencies installed successfully"
}

# Build a single variant
build_variant() {
  local arch=$1
  local backends=$2
  local coreml=$3
  local metal=$4
  local vulkan=$5
  local build_type=$6
  local llm=${7:-OFF}
  local mlx=${8:-OFF}
  local build_type_lower=$(echo "$build_type" | tr '[:upper:]' '[:lower:]')
  local build_dir="${PROJECT_DIR}/build-${PLATFORM}-${arch}-${backends}-${build_type_lower}"
  local artifact_name="libexecutorch_ffi-${PLATFORM}-${arch}-${backends}-${build_type_lower}.tar.gz"
  # MLX requires a macOS 14.0+ deployment target; everything else uses 11.0.
  local deploy=11.0
  [ "$mlx" = "ON" ] && deploy=14.0

  # COMPILE-ONCE / LINK-MANY (executorch_native#6): all variants that share the
  # same (arch, build_type, deployment-target) compile ExecuTorch into ONE shared
  # sub-build directory, so the first variant compiles it and the rest hit ccache
  # (the variant's wrapper still links only its own backend subset). MLX's 14.0
  # deployment target gets its own shared dir so the version-min flag change does
  # not invalidate the 11.0 cache.
  # d14 holds only the MLX variant, so its superset is the MLX set; d11
  # holds the eight tensor variants plus xnnpack-llm.
  local superset="xnnpack;coreml;metal;vulkan;llm"
  [ "$mlx" = "ON" ] && superset="xnnpack;mlx;llm"
  local et_class="d${deploy%%.*}"
  local shared_et_dir="${PROJECT_DIR}/.et-shared/${PLATFORM}-${arch}-${build_type_lower}-${et_class}"

  echo ""
  echo "=== Building ${PLATFORM}-${arch}-${backends}-${build_type_lower} ==="
  echo "  Build directory: ${build_dir}"
  echo "  Backends: XNNPACK=ON, CoreML=${coreml}, Metal=${metal}, Vulkan=${vulkan}, MLX=${mlx}, LLM=${llm}"

  # Check Vulkan requirement
  if [ "$vulkan" = "ON" ]; then
    if ! check_vulkan; then
      echo "ERROR: Vulkan variant requested but glslc not found"
      echo "Please install: brew install shaderc molten-vk"
      exit 1
    fi
    echo "  Vulkan: enabled (glslc found)"
  fi

  # Configure
  cmake -B "$build_dir" -S "$PROJECT_DIR" \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${deploy}" \
    -DEXECUTORCH_VERSION="${VERSION}" \
    -DEXECUTORCH_BUILD_MODE=source \
    -DEXECUTORCH_CACHE_DIR="${CACHE_DIR}" \
    -DEXECUTORCH_SHARED_BINARY_DIR="${shared_et_dir}" \
    -DET_BUILD_XNNPACK=ON \
    -DET_BUILD_COREML="${coreml}" \
    -DET_BUILD_METAL="${metal}" \
    -DET_BUILD_VULKAN="${vulkan}" \
    -DET_BUILD_MLX="${mlx}" \
    -DET_BUILD_LLM="${llm}" \
    -DET_BUILD_QNN=OFF \
    -DET_SUPERSET_BACKENDS="${superset}" \
    -DCMAKE_INSTALL_PREFIX="${build_dir}/install"

  # Build
  cmake --build "$build_dir" --config "${build_type}" --parallel $(sysctl -n hw.ncpu)

  # Install
  cmake --install "$build_dir" --config "${build_type}"

  # Bundle MoltenVK for Vulkan variants
  if [ "$vulkan" = "ON" ]; then
    bundle_moltenvk "${build_dir}/install"
  fi

  # Bundle libomp for Metal variants (AOTI runtime needs OpenMP)
  if [ "$metal" = "ON" ]; then
    bundle_libomp "${build_dir}/install"
  fi

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
  IFS=':' read -r backends coreml metal vulkan <<< "$variant"
  build_variant "arm64" "$backends" "$coreml" "$metal" "$vulkan" "Release"
  build_variant "arm64" "$backends" "$coreml" "$metal" "$vulkan" "Debug"
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

# Build LLM variants (arm64). xnnpack-mlx-llm needs the Xcode Metal Toolchain.
echo ""
echo "============================================================"
echo "Building arm64 LLM variants (${#ARM64_LLM_VARIANTS[@]})"
echo "============================================================"
for variant in "${ARM64_LLM_VARIANTS[@]}"; do
  IFS=':' read -r backends coreml metal vulkan mlx llm <<< "$variant"
  build_variant "arm64" "$backends" "$coreml" "$metal" "$vulkan" "Release" "$llm" "$mlx"
  build_variant "arm64" "$backends" "$coreml" "$metal" "$vulkan" "Debug" "$llm" "$mlx"
done

# Build LLM variants (x86_64) — CPU only (no MLX on Intel).
echo ""
echo "============================================================"
echo "Building x86_64 LLM variants (${#X64_LLM_VARIANTS[@]})"
echo "============================================================"
for variant in "${X64_LLM_VARIANTS[@]}"; do
  IFS=':' read -r backends coreml metal vulkan mlx llm <<< "$variant"
  build_variant "x86_64" "$backends" "$coreml" "OFF" "$vulkan" "Release" "$llm" "OFF"
  build_variant "x86_64" "$backends" "$coreml" "OFF" "$vulkan" "Debug" "$llm" "OFF"
done

echo ""
echo "============================================================"
echo "Build Complete!"
echo "============================================================"
echo "Artifacts built: $(ls dist/*.tar.gz 2>/dev/null | wc -l)"
ls -la dist/*.tar.gz 2>/dev/null || echo "No artifacts found"
echo "============================================================"
