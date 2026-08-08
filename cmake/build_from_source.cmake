# build_from_source.cmake
# Builds ExecuTorch from source using FetchContent

message(STATUS "Building ExecuTorch from source...")
message(STATUS "  This requires Python 3.8+ with pyyaml package")
message(STATUS "  Build may take 15-30 minutes on first run")

# ============================================================================
# Python Setup
# ============================================================================

if(NOT PYTHON_EXECUTABLE)
    set(Python3_FIND_FRAMEWORK NEVER)
    set(Python3_FIND_STRATEGY LOCATION)
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(PYTHON_EXECUTABLE ${Python3_EXECUTABLE} CACHE STRING "Python executable" FORCE)
endif()
message(STATUS "Using Python: ${PYTHON_EXECUTABLE}")

# ============================================================================
# Caching Configuration
# ============================================================================

if(DEFINED EXECUTORCH_CACHE_DIR AND NOT "${EXECUTORCH_CACHE_DIR}" STREQUAL "")
    if(NOT EXISTS "${EXECUTORCH_CACHE_DIR}")
        file(MAKE_DIRECTORY "${EXECUTORCH_CACHE_DIR}")
    endif()
    set(FETCHCONTENT_BASE_DIR
        "${EXECUTORCH_CACHE_DIR}/${CMAKE_SYSTEM_NAME}/${CMAKE_SYSTEM_PROCESSOR}"
        CACHE PATH "FetchContent cache directory" FORCE)
    message(STATUS "Using cache directory: ${FETCHCONTENT_BASE_DIR}")
endif()

# ============================================================================
# ExecuTorch Source Configuration
# ============================================================================

# Use shared source directory when cache is enabled to avoid re-cloning
# for each build variant. Binary dir must remain per-build for different configs.
# IMPORTANT: ExecuTorch requires the directory to be named exactly "executorch"
# See: https://github.com/pytorch/executorch/issues/6475
if(DEFINED EXECUTORCH_CACHE_DIR AND NOT "${EXECUTORCH_CACHE_DIR}" STREQUAL "")
    # Normalize path to use forward slashes (fixes Windows path issues)
    file(TO_CMAKE_PATH "${EXECUTORCH_CACHE_DIR}" _normalized_cache_dir)
    set(executorch_SOURCE_DIR "${_normalized_cache_dir}/executorch")
else()
    set(executorch_SOURCE_DIR ${CMAKE_BINARY_DIR}/executorch)
endif()

# ExecuTorch sub-build binary directory.
#
# COMPILE-ONCE / LINK-MANY (executorch_native#6): by default each shipped variant
# (xnnpack, xnnpack-coreml, xnnpack-metal, ...) builds ExecuTorch from scratch in
# its OWN per-variant tree. The variant name lives inside the ExecuTorch
# generated-header `-I` paths, so even though the source + flags match across
# variants, ccache sees different command lines and MISSES — every backend variant
# recompiles all of ExecuTorch (measured: ~41% intra-run hits, ~hours per release).
#
# When EXECUTORCH_SHARED_BINARY_DIR is passed, all variants that share a
# (platform, arch, build_type, deployment-target) key point ExecuTorch's sub-build
# at ONE shared directory. The paths in every compile command then become
# identical across variants, so the first variant compiles ExecuTorch once and the
# rest are served from ccache (the wrapper itself still links only its own backend
# subset, so each shipped library stays slim). Different deployment targets
# (e.g. MLX needs macOS 14 vs 11 elsewhere) MUST use distinct shared dirs, or the
# `-mmacosx-version-min` flag change defeats the cache — the build scripts key the
# path on the deployment class for exactly this reason.
if(DEFINED EXECUTORCH_SHARED_BINARY_DIR AND NOT "${EXECUTORCH_SHARED_BINARY_DIR}" STREQUAL "")
    file(TO_CMAKE_PATH "${EXECUTORCH_SHARED_BINARY_DIR}" executorch_BINARY_DIR)
    message(STATUS "Using SHARED ExecuTorch binary dir (compile-once/link-many): ${executorch_BINARY_DIR}")
else()
    set(executorch_BINARY_DIR ${CMAKE_BINARY_DIR}/_deps/executorch_fetch-build)
endif()

# ExecuTorch build options (must be set before FetchContent_MakeAvailable)
set(EXECUTORCH_BUILD_HOST_TARGETS ON CACHE BOOL "Build host targets" FORCE)
set(EXECUTORCH_BUILD_FLATC ON CACHE BOOL "Build flatc" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_MODULE ON CACHE BOOL "Build extension module" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR ON CACHE BOOL "Build flat tensor extension" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP ON CACHE BOOL "Build named data map extension" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL ON CACHE BOOL "Build runner util extension" FORCE)

# COMPILE-ONCE / LINK-MANY, part two.
#
# Pointing every variant at one shared ExecuTorch sub-build directory only pays
# off if the compile commands match. They did not. Each variant reconfigured
# that shared directory with different -DET_BUILD_* values, those propagate into
# ExecuTorch's own targets, so CMake rebuilt them and ccache missed.
#
# Measured on the v1.3.1.9 macOS job: 7078 object compiles for 4087 distinct
# objects (42% redundant), core files rebuilt 9 times inside a single shared dir
# -- once per variant sharing it -- and a 33% ccache hit rate, below the ~41%
# this mechanism was introduced to beat.
#
# ET_SUPERSET_BACKENDS makes the sub-build a superset of every backend the
# platform ships, so it is identical across variants and genuinely compiles once.
# ET_BUILD_* is deliberately left alone: it still decides what the wrapper LINKS
# and what the variant is named, so shipped libraries stay exactly as slim as
# before. Variant differences move from compile time to link time.
#
# The list comes from the build scripts rather than being inferred here, because
# each platform ships a different set -- iOS has no Metal, Linux and Android are
# XNNPACK+Vulkan only -- and guessing wrong turns a fast build into a broken one.
set(ET_SUPERSET_BACKENDS "" CACHE STRING
    "Backends compiled into the shared ExecuTorch sub-build (superset)")

function(_et_effective backend requested out_var)
    if("${backend}" IN_LIST ET_SUPERSET_BACKENDS)
        set(${out_var} ON PARENT_SCOPE)
    else()
        set(${out_var} ${requested} PARENT_SCOPE)
    endif()
endfunction()

if(NOT "${ET_SUPERSET_BACKENDS}" STREQUAL "")
    message(STATUS "ExecuTorch sub-build superset: ${ET_SUPERSET_BACKENDS}")
endif()

_et_effective(xnnpack "${ET_BUILD_XNNPACK}" _want_xnnpack)
_et_effective(coreml  "${ET_BUILD_COREML}"  _want_coreml)
_et_effective(mps     "${ET_BUILD_MPS}"     _want_mps)
_et_effective(metal   "${ET_BUILD_METAL}"   _want_metal)
_et_effective(mlx     "${ET_BUILD_MLX}"     _want_mlx)
_et_effective(vulkan  "${ET_BUILD_VULKAN}"  _want_vulkan)
_et_effective(llm     "${ET_BUILD_LLM}"     _want_llm)

# LLM (text generation) runner + tokenizers. Built whenever the superset asks
# for it, so an LLM variant sharing a directory with tensor variants does not
# toggle the option and invalidate everything.
if(_want_llm)
    set(EXECUTORCH_BUILD_EXTENSION_LLM ON CACHE BOOL "Build LLM extension" FORCE)
    set(EXECUTORCH_BUILD_EXTENSION_LLM_RUNNER ON CACHE BOOL "Build LLM runner extension" FORCE)
    # Quantized LLM .pte files (optimum 8da4w linears + 8w embedding) call ops that run
    # OUTSIDE the XNNPACK delegate — notably the quantized embedding lookup — which the
    # runner hits on the first decode step. Without quantized_ops_lib the model loads
    # (op resolution is lazy) but generate() fails with Error::OperatorMissing (0x14).
    # quantized_ops_lib registers the quantized_decomposed::* namespace, which is purely
    # additive to portable_ops_lib's aten::* — no double-registration.
    #
    # We deliberately do NOT enable EXECUTORCH_BUILD_KERNELS_LLM (custom_ops, llm::*
    # sdpa_with_kv_cache etc.): (1) upstream's preset hard-requires KERNELS_OPTIMIZED
    # whenever KERNELS_LLM is on (tools/cmake/preset/default.cmake:391), and OPTIMIZED
    # is a superset of portable that re-registers the same aten::* ops -> would force a
    # portable->optimized swap to avoid Error::RegistrationAlreadyRegistered (0x16);
    # and (2) our optimum export drops --use_custom_sdpa/--use_custom_kv_cache, so the
    # graph contains NO llm::* custom ops to begin with. If a future export needs them,
    # enable KERNELS_LLM + KERNELS_OPTIMIZED together and swap portable->optimized.
    set(EXECUTORCH_BUILD_KERNELS_QUANTIZED ON CACHE BOOL "Build quantized kernels" FORCE)
    # Explicitly force OFF (not just "leave unset"): a prior configure may have cached
    # KERNELS_LLM=ON, and the preset hard-requires KERNELS_OPTIMIZED whenever it's on.
    set(EXECUTORCH_BUILD_KERNELS_LLM OFF CACHE BOOL "Build LLM custom kernels" FORCE)

    # Enable ExecuTorch's INTERNAL logging at Error level so LLM load/generate
    # failures surface with a message + location instead of a bare code (e.g.
    # NotSupported 0x10). Without ENABLE_LOGGING, ET_LOG() is compiled out
    # (ET_LOG_ENABLED=0). Error level avoids the verbose per-method Debug spam
    # (and its perf cost) while keeping diagnostics useful. This is a COMPILE-TIME
    # option, independent of the pubspec `debug:` flag.
    set(EXECUTORCH_ENABLE_LOGGING ON CACHE BOOL "Enable ExecuTorch ET_LOG" FORCE)
    set(EXECUTORCH_LOG_LEVEL "Error" CACHE STRING "ExecuTorch log verbosity" FORCE)
endif()

# KleidiAI provides XNNPACK's ARM SME/SVE2 perf microkernels, which pull `kai/`
# headers fetched at configure time. Those can be missing/unwired in a local source
# build (fatal "kai/...sme_dot.h not found"). It is perf-only with no functional
# impact, so disable it for source builds to keep XNNPACK compiling cleanly.
set(EXECUTORCH_XNNPACK_ENABLE_KLEIDI OFF CACHE BOOL "Disable KleidiAI" FORCE)
set(XNNPACK_ENABLE_KLEIDIAI OFF CACHE BOOL "Disable KleidiAI" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_DATA_LOADER ON CACHE BOOL "Build data loader extension" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_TENSOR ON CACHE BOOL "Build tensor extension" FORCE)
set(EXECUTORCH_BUILD_KERNELS_PORTABLE ON CACHE BOOL "Build portable kernels" FORCE)
set(EXECUTORCH_BUILD_KERNELS_OPTIMIZED OFF CACHE BOOL "Build optimized kernels" FORCE)
set(EXECUTORCH_BUILD_DEVTOOLS OFF CACHE BOOL "Build devtools" FORCE)
set(EXECUTORCH_BUILD_SDK OFF CACHE BOOL "Build SDK" FORCE)
set(EXECUTORCH_BUILD_TESTS OFF CACHE BOOL "Build tests" FORCE)
set(EXECUTORCH_BUILD_EXAMPLES OFF CACHE BOOL "Build examples" FORCE)
set(EXECUTORCH_BUILD_PYBIND OFF CACHE BOOL "Build pybind" FORCE)

# Backend options - debug output
message(STATUS "ET_BUILD_XNNPACK input: ${ET_BUILD_XNNPACK}")
message(STATUS "ET_BUILD_COREML input: ${ET_BUILD_COREML}")
message(STATUS "ET_BUILD_MPS input: ${ET_BUILD_MPS}")
message(STATUS "ET_BUILD_VULKAN input: ${ET_BUILD_VULKAN}")
message(STATUS "ET_BUILD_QNN input: ${ET_BUILD_QNN}")

if(_want_xnnpack)
    set(EXECUTORCH_BUILD_XNNPACK ON CACHE BOOL "Build XNNPACK backend" FORCE)
else()
    set(EXECUTORCH_BUILD_XNNPACK OFF CACHE BOOL "Build XNNPACK backend" FORCE)
endif()

if(_want_coreml AND APPLE)
    set(EXECUTORCH_BUILD_COREML ON CACHE BOOL "Build CoreML backend" FORCE)
else()
    set(EXECUTORCH_BUILD_COREML OFF CACHE BOOL "Build CoreML backend" FORCE)
endif()

if(_want_mps AND APPLE)
    set(EXECUTORCH_BUILD_MPS ON CACHE BOOL "Build MPS backend" FORCE)
else()
    set(EXECUTORCH_BUILD_MPS OFF CACHE BOOL "Build MPS backend" FORCE)
endif()

# Metal backend (macOS-only): an AOTI-based delegate. Requires the
# tensor extension and pulls in the shared AOTI runtime (aoti_common). Needs a
# matching PyTorch + pyyaml available at build time (see build scripts).
if(_want_metal AND APPLE)
    set(EXECUTORCH_BUILD_METAL ON CACHE BOOL "Build Metal backend" FORCE)
    set(EXECUTORCH_BUILD_EXTENSION_TENSOR ON CACHE BOOL "Build tensor extension" FORCE)
else()
    set(EXECUTORCH_BUILD_METAL OFF CACHE BOOL "Build Metal backend" FORCE)
endif()

# MLX backend (Apple-Silicon GPU, macOS desktop): the native runtime for
# Gemma 4 LLMs exported with the MLX partitioner (--qlinear 4w
# --use-custom-sdpa --use-custom-kv-cache). Distinct from the Metal-AOTI
# backend above. Builds MLX from the backends/mlx/third-party/mlx submodule
# (Metal-only, JIT kernels) and links the mlxdelegate.
#
# Kernels: we keep the default PORTABLE kernels (NOT the optimized set the
# upstream mlx preset uses). On Xcode 26.5 / ET 1.3.1 the optimized kernels fail
# to compile — kernels/portable/cpu/util/upsample_util.cpp instantiates
# memory_allocator.h's allocateList<T>, whose c10::mul_overflows(size_t,...) call
# does not match the uint64_t* overload on arm64-macOS (size_t = unsigned long !=
# uint64_t = unsigned long long); this is the same array_ref.h/mul_overflows bug
# that blocks the Metal-AOTI backend (executorch#19907). MLX does NOT need
# optimized: its sdpa/kv run inside the MLX delegate, and the model's only graph
# fallback (aten.bitwise_or) is provided by portable_ops_lib. Staying on portable
# also avoids the optimized<->portable aten::* double-registration (0x16).
#
# Hard requirement: deployment target >= macOS 14.0 (the MLX CMakeLists
# FATAL_ERRORs below that).
if(_want_mlx AND APPLE)
    set(EXECUTORCH_BUILD_MLX ON CACHE BOOL "Build MLX backend" FORCE)
    set(EXECUTORCH_BUILD_EXTENSION_TENSOR ON CACHE BOOL "Build tensor extension" FORCE)
    # MLX requires macOS 14.0+. backends/mlx/CMakeLists.txt picks its minimum from
    # ONE of three branches, and which one fires depends on how the build is driven:
    #   1. ios.toolchain macOS (PLATFORM matches ^MAC)            -> checks DEPLOYMENT_TARGET, min 14
    #   2. ios.toolchain iOS/etc (DEPLOYMENT_TARGET set, not MAC) -> min 17
    #   3. plain macOS (only CMAKE_OSX_DEPLOYMENT_TARGET set)     -> min 14
    # Flutter builds via native_toolchain_cmake (ios.toolchain, PLATFORM=MAC_ARM64,
    # DEPLOYMENT_TARGET defaulting to 13) take branch 1, so we must raise
    # DEPLOYMENT_TARGET to 14. The CI build-macos.sh path is a PLAIN macOS build
    # with NO PLATFORM — there, setting DEPLOYMENT_TARGET wrongly trips branch 2
    # (the iOS path, min 17) and FATAL_ERRORs at 14. So only set DEPLOYMENT_TARGET
    # when the ios.toolchain macOS path is active; otherwise rely on branch 3 via
    # CMAKE_OSX_DEPLOYMENT_TARGET alone. Both are forced before add_subdirectory so
    # every ET/MLX target also compiles for macOS 14 (MLX's 14-only Metal APIs).
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "MLX requires macOS 14+" FORCE)
    if(PLATFORM MATCHES "^MAC")
        set(DEPLOYMENT_TARGET "14.0" CACHE STRING "MLX requires macOS 14+" FORCE)
    endif()
else()
    set(EXECUTORCH_BUILD_MLX OFF CACHE BOOL "Build MLX backend" FORCE)
endif()

# Vulkan requires glslc compiler - check availability when requested
if(_want_vulkan)
    find_program(GLSLC_EXECUTABLE glslc
        HINTS
            $ENV{VULKAN_SDK}/bin
            /usr/bin
            /usr/local/bin
    )
    if(NOT GLSLC_EXECUTABLE)
        message(WARNING "glslc not found - Vulkan backend requires glslc compiler")
        message(WARNING "Install Vulkan SDK 1.4.321.0+ or set VULKAN_SDK environment variable")
        message(WARNING "Disabling Vulkan backend")
        set(EXECUTORCH_BUILD_VULKAN OFF CACHE BOOL "Build Vulkan backend" FORCE)
    else()
        message(STATUS "Found glslc: ${GLSLC_EXECUTABLE}")
        # Log glslc version for debugging - an old version may lack
        # GL_EXT_integer_dot_product support required by upstream ExecuTorch
        execute_process(
            COMMAND ${GLSLC_EXECUTABLE} --version
            OUTPUT_VARIABLE _glslc_version_output
            ERROR_VARIABLE _glslc_version_output
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        message(STATUS "glslc version: ${_glslc_version_output}")
        set(EXECUTORCH_BUILD_VULKAN ON CACHE BOOL "Build Vulkan backend" FORCE)
    endif()
else()
    set(EXECUTORCH_BUILD_VULKAN OFF CACHE BOOL "Build Vulkan backend" FORCE)
endif()

if(ET_BUILD_QNN)
    set(EXECUTORCH_BUILD_QNN ON CACHE BOOL "Build QNN backend" FORCE)
else()
    set(EXECUTORCH_BUILD_QNN OFF CACHE BOOL "Build QNN backend" FORCE)
endif()

# ============================================================================
# PYTHONPATH Setup for ExecuTorch codegen
# ============================================================================

# Remember the real interpreter across re-configures. PYTHON_EXECUTABLE is
# FORCE-overwritten with the wrapper path below, so on any reconfigure the
# wrapper would otherwise be written to exec itself (infinite recursion:
# "Argument list too long" / "Undefined error: 0" from Codegen.cmake).
if(NOT PYTHON_EXECUTABLE MATCHES "python_wrapper")
    set(EXECUTORCH_ORIGINAL_PYTHON ${PYTHON_EXECUTABLE} CACHE STRING "Real Python interpreter wrapped for codegen" FORCE)
endif()
if(NOT DEFINED EXECUTORCH_ORIGINAL_PYTHON)
    message(FATAL_ERROR
        "PYTHON_EXECUTABLE points at the generated wrapper and no original "
        "interpreter is cached. Re-run cmake with -DPYTHON_EXECUTABLE=/path/to/python3")
endif()
set(_original_python ${EXECUTORCH_ORIGINAL_PYTHON})
set(_python_wrapper_dir ${CMAKE_BINARY_DIR}/python_wrapper)
file(MAKE_DIRECTORY ${_python_wrapper_dir})

# PYTHONPATH needs to point to the PARENT of executorch so Python can find 'executorch' package
# executorch_SOURCE_DIR = ${CMAKE_BINARY_DIR}/executorch
# So PYTHONPATH should be ${CMAKE_BINARY_DIR} to allow 'from executorch.codegen import ...'
set(_pythonpath_dir ${CMAKE_BINARY_DIR})

if(WIN32)
    set(_python_wrapper ${_python_wrapper_dir}/python_wrapper.bat)
    file(WRITE ${_python_wrapper}
"@echo off
set PYTHONPATH=${_pythonpath_dir};%PYTHONPATH%
\"${_original_python}\" %*
")
else()
    set(_python_wrapper ${_python_wrapper_dir}/python_wrapper.sh)
    file(WRITE ${_python_wrapper}
"#!/bin/bash
export PYTHONPATH=\"${_pythonpath_dir}:\$PYTHONPATH\"
exec \"${_original_python}\" \"$@\"
")
    execute_process(COMMAND chmod +x ${_python_wrapper})
endif()

set(PYTHON_EXECUTABLE ${_python_wrapper} CACHE STRING "Python wrapper with PYTHONPATH" FORCE)
message(STATUS "Using Python wrapper: ${PYTHON_EXECUTABLE}")

# ============================================================================
# Fetch ExecuTorch Source
# ============================================================================

# Define all possible submodules
set(_core_submodules
    # Core dependencies
    third-party/flatbuffers
    third-party/flatcc
    third-party/json
    third-party/gflags
    # XNNPACK backend (always needed as base)
    backends/xnnpack/third-party/XNNPACK
    backends/xnnpack/third-party/cpuinfo
    backends/xnnpack/third-party/pthreadpool
    backends/xnnpack/third-party/FP16
    backends/xnnpack/third-party/FXdiv
    # Note: CoreML and MPS use system frameworks, no external submodules
)

# Vulkan backend submodules (only needed when Vulkan is enabled)
set(_vulkan_submodules
    backends/vulkan/third-party/Vulkan-Headers
    backends/vulkan/third-party/VulkanMemoryAllocator
    backends/vulkan/third-party/volk
)

if(EXISTS "${executorch_SOURCE_DIR}/CMakeLists.txt")
    message(STATUS "ExecuTorch v${EXECUTORCH_VERSION} already present at ${executorch_SOURCE_DIR}")

    # If Vulkan is requested, verify required files are present
    if(EXECUTORCH_BUILD_VULKAN)
        # Check for Vulkan GLSL shaders (required for shader compilation)
        set(_vulkan_glsl_dir "${executorch_SOURCE_DIR}/backends/vulkan/runtime/graph/ops/glsl")
        file(GLOB _vulkan_glsl_files "${_vulkan_glsl_dir}/*.glsl")
        list(LENGTH _vulkan_glsl_files _glsl_count)

        if(_glsl_count EQUAL 0)
            message(STATUS "Vulkan GLSL shaders missing (found ${_glsl_count} files), restoring...")
            # Use git checkout to restore any missing files in the vulkan backend
            execute_process(
                COMMAND git checkout HEAD -- backends/vulkan/
                WORKING_DIRECTORY ${executorch_SOURCE_DIR}
                RESULT_VARIABLE _git_result
            )
            if(NOT _git_result EQUAL 0)
                message(WARNING "Failed to restore Vulkan backend files. Disabling Vulkan backend.")
                set(EXECUTORCH_BUILD_VULKAN OFF CACHE BOOL "Build Vulkan backend" FORCE)
            else()
                # Verify files are now present
                file(GLOB _vulkan_glsl_files "${_vulkan_glsl_dir}/*.glsl")
                list(LENGTH _vulkan_glsl_files _glsl_count)
                message(STATUS "Vulkan GLSL shaders restored (found ${_glsl_count} files)")
            endif()
        else()
            message(STATUS "Vulkan GLSL shaders present (found ${_glsl_count} files)")
        endif()

        # Check for Vulkan submodules
        set(_vulkan_submodules_missing FALSE)
        foreach(_submod ${_vulkan_submodules})
            if(NOT EXISTS "${executorch_SOURCE_DIR}/${_submod}/CMakeLists.txt"
               AND NOT EXISTS "${executorch_SOURCE_DIR}/${_submod}/include")
                set(_vulkan_submodules_missing TRUE)
                break()
            endif()
        endforeach()

        if(_vulkan_submodules_missing)
            message(STATUS "Vulkan submodules missing, fetching them...")
            execute_process(
                COMMAND git submodule update --init --recursive
                    backends/vulkan/third-party/Vulkan-Headers
                    backends/vulkan/third-party/VulkanMemoryAllocator
                    backends/vulkan/third-party/volk
                WORKING_DIRECTORY ${executorch_SOURCE_DIR}
                RESULT_VARIABLE _git_result
            )
            if(NOT _git_result EQUAL 0)
                message(WARNING "Failed to fetch Vulkan submodules. Disabling Vulkan backend.")
                set(EXECUTORCH_BUILD_VULKAN OFF CACHE BOOL "Build Vulkan backend" FORCE)
            else()
                message(STATUS "Vulkan submodules fetched successfully")
            endif()
        endif()
    endif()
else()
    message(STATUS "Fetching ExecuTorch v${EXECUTORCH_VERSION}...")

    set(FETCHCONTENT_QUIET FALSE)

    # Start with core submodules
    set(_git_submodules ${_core_submodules})

    # Add Vulkan submodules if Vulkan backend is enabled
    if(EXECUTORCH_BUILD_VULKAN)
        message(STATUS "Including Vulkan submodules for initial fetch")
        list(APPEND _git_submodules ${_vulkan_submodules})
    endif()

    message(STATUS "Git submodules to fetch: ${_git_submodules}")

    FetchContent_Declare(
        executorch_fetch
        GIT_REPOSITORY https://github.com/pytorch/executorch.git
        GIT_TAG v${EXECUTORCH_VERSION}
        GIT_SHALLOW TRUE
        GIT_PROGRESS TRUE
        SOURCE_DIR ${executorch_SOURCE_DIR}
        GIT_SUBMODULES ${_git_submodules}
    )

    # Use FetchContent_Populate instead of MakeAvailable for more control
    # MakeAvailable automatically calls add_subdirectory which can cause timing issues
    FetchContent_Populate(executorch_fetch)
    message(STATUS "ExecuTorch fetched successfully to ${executorch_SOURCE_DIR}")
endif()

# Note: EXECUTORCH_BUILD_VULKAN was already set earlier based on glslc availability
# No need to force it OFF here - we respect the computed value

# Diagnostic: Check for Vulkan GLSL files before adding subdirectory
set(_vulkan_glsl_dir "${executorch_SOURCE_DIR}/backends/vulkan/runtime/graph/ops/glsl")
message(STATUS "Checking Vulkan GLSL directory: ${_vulkan_glsl_dir}")
if(EXISTS "${_vulkan_glsl_dir}")
    file(GLOB _all_glsl_files "${_vulkan_glsl_dir}/*.glsl")
    list(LENGTH _all_glsl_files _total_glsl_count)
    message(STATUS "  Directory exists, found ${_total_glsl_count} .glsl files")
    if(_total_glsl_count GREATER 0)
        list(GET _all_glsl_files 0 _first_file)
        message(STATUS "  First file: ${_first_file}")
    endif()
else()
    message(STATUS "  Directory does NOT exist!")
    # List the parent directory to see what's there
    set(_vulkan_ops_dir "${executorch_SOURCE_DIR}/backends/vulkan/runtime/graph/ops")
    if(EXISTS "${_vulkan_ops_dir}")
        file(GLOB _ops_contents "${_vulkan_ops_dir}/*")
        message(STATUS "  Contents of ${_vulkan_ops_dir}:")
        foreach(_item ${_ops_contents})
            message(STATUS "    ${_item}")
        endforeach()
    else()
        message(STATUS "  Parent directory ${_vulkan_ops_dir} also does NOT exist!")
    endif()
endif()

# ============================================================================
# Patch ExecuTorch's gen_vulkan_spv.py for Windows CRLF line endings
# ============================================================================
# ExecuTorch's gen_vulkan_spv.py has a bug where the regex r"\\$" doesn't handle
# Windows CRLF line endings. The $ matches before \n, but with CRLF there's a \r
# between the backslash and end-of-line, so macro continuations don't get escaped.
# This causes "unterminated string literal" errors on Windows.

if(EXECUTORCH_BUILD_VULKAN AND WIN32)
    set(_gen_vulkan_spv "${executorch_SOURCE_DIR}/backends/vulkan/runtime/gen_vulkan_spv.py")
    if(EXISTS "${_gen_vulkan_spv}")
        message(STATUS "Patching gen_vulkan_spv.py for Windows CRLF support...")
        file(READ "${_gen_vulkan_spv}" _gen_spv_content)

        # Check if already patched
        string(FIND "${_gen_spv_content}" "PATCHED_FOR_CRLF" _already_patched_crlf)

        if(_already_patched_crlf EQUAL -1)
            # The original regex r"\\$" doesn't match backslash before \r\n on Windows
            # Change it to r"\\\\r?$" to handle both LF and CRLF line endings
            string(REPLACE
                [[input_text = re.sub(r"\\$", r"\\\\", input_text, flags=re.MULTILINE)]]
                [[# PATCHED_FOR_CRLF: Handle Windows CRLF line endings
    input_text = input_text.replace("\r\n", "\n")  # Normalize line endings first
    input_text = re.sub(r"\\$", r"\\\\", input_text, flags=re.MULTILINE)]]
                _gen_spv_content "${_gen_spv_content}")

            file(WRITE "${_gen_vulkan_spv}" "${_gen_spv_content}")
            message(STATUS "gen_vulkan_spv.py patched for Windows CRLF support")
        else()
            message(STATUS "gen_vulkan_spv.py already patched for CRLF, skipping")
        endif()
    endif()
endif()

# ============================================================================
# Patch ExecuTorch's ShaderLibrary.cmake for Vulkan builds
# ============================================================================
# ExecuTorch's ShaderLibrary.cmake has a bug where it uses DEPENDS ${shaders_path}/*
# but CMake's add_custom_command doesn't expand glob patterns - it creates a literal
# dependency on a file named "*" which doesn't exist.
# We patch this by using file(GLOB) to expand the pattern properly.

if(EXECUTORCH_BUILD_VULKAN)
    set(_shader_library_cmake "${executorch_SOURCE_DIR}/backends/vulkan/cmake/ShaderLibrary.cmake")
    if(EXISTS "${_shader_library_cmake}")
        message(STATUS "Patching ShaderLibrary.cmake for glob expansion...")
        file(READ "${_shader_library_cmake}" _shader_lib_content)

        # Check if already patched (avoid double-patching)
        string(FIND "${_shader_lib_content}" "_ET_SHADER_GLOB_DEPS" _already_patched)

        if(_already_patched EQUAL -1)
            # CMake's add_custom_command DEPENDS doesn't expand glob patterns like ${path}/*
            # It creates a literal dependency on a file named "*" which doesn't exist
            # We patch this by:
            # 1. Adding a file(GLOB) call at the start of the gen_vulkan_shader_lib_cpp function
            # 2. Replacing the wildcard DEPENDS with the glob result variable

            # Step 1: Insert file(GLOB) at the start of the function
            # This ensures the glob is expanded before the add_custom_command
            string(REPLACE
                "function(gen_vulkan_shader_lib_cpp shaders_path)"
                "function(gen_vulkan_shader_lib_cpp shaders_path)
  # Expand shader glob pattern (CMake DEPENDS doesn't support wildcards)
  # Patched by executorch_native build system
  file(GLOB _ET_SHADER_GLOB_DEPS \"\${shaders_path}/*.glsl\" \"\${shaders_path}/*.glslh\")"
                _shader_lib_content "${_shader_lib_content}")

            # Step 2: Replace the wildcard DEPENDS with the expanded variable
            string(REPLACE
                "DEPENDS \${shaders_path}/*"
                "DEPENDS \${_ET_SHADER_GLOB_DEPS}"
                _shader_lib_content "${_shader_lib_content}")

            file(WRITE "${_shader_library_cmake}" "${_shader_lib_content}")
            message(STATUS "ShaderLibrary.cmake patched successfully")

            # Verify the patch worked
            file(READ "${_shader_library_cmake}" _verify_content)
            string(FIND "${_verify_content}" "_ET_SHADER_GLOB_DEPS" _patch_verified)
            if(_patch_verified EQUAL -1)
                message(WARNING "Patch verification failed - the pattern may not have matched")
                message(STATUS "Looking for DEPENDS pattern in ShaderLibrary.cmake...")
                string(FIND "${_verify_content}" "DEPENDS \${shaders_path}" _found_original)
                if(NOT _found_original EQUAL -1)
                    message(STATUS "  Original pattern still exists - replacement failed")
                endif()
            else()
                message(STATUS "Patch verified successfully")
            endif()
        else()
            message(STATUS "ShaderLibrary.cmake already patched, skipping")
        endif()
    else()
        message(WARNING "ShaderLibrary.cmake not found at ${_shader_library_cmake}")
    endif()
endif()

# The LLM runner pulls in the tokenizers library, which lives in the
# extension/llm/tokenizers GIT SUBMODULE (and has its OWN nested submodules:
# sentencepiece, re2, abseil, pcre2, json, ...). FetchContent only clones the
# submodules listed at clone time (the _core_submodules above), so a fresh CI
# clone is missing it and configure dies with "add_subdirectory ... does not
# contain a CMakeLists.txt: extension/llm/tokenizers". Init it (recursively) on
# demand, the same way the MLX/eigen submodules are handled below.
if(ET_BUILD_LLM OR ET_BUILD_TOKENIZER)
    set(_tokenizers_dir "${executorch_SOURCE_DIR}/extension/llm/tokenizers")
    if(NOT EXISTS "${_tokenizers_dir}/CMakeLists.txt")
        message(STATUS "LLM tokenizers submodule missing, fetching (recursive)...")
        execute_process(
            COMMAND git submodule update --init --recursive extension/llm/tokenizers
            WORKING_DIRECTORY ${executorch_SOURCE_DIR}
            RESULT_VARIABLE _tokenizers_result
        )
        if(NOT _tokenizers_result EQUAL 0
           OR NOT EXISTS "${_tokenizers_dir}/CMakeLists.txt")
            message(FATAL_ERROR
                "Failed to initialize the tokenizers submodule at ${_tokenizers_dir}.\n"
                "Run manually: cd ${executorch_SOURCE_DIR} && "
                "git submodule update --init --recursive extension/llm/tokenizers")
        endif()
        message(STATUS "LLM tokenizers submodule fetched successfully")
    else()
        message(STATUS "LLM tokenizers submodule present at ${_tokenizers_dir}")
    endif()
endif()

# Sentencepiece (pulled in by the LLM tokenizers library) marks its CLI tools
# (spm_encode, spm_train, ...) as MACOSX_BUNDLE under the Xcode generator, and
# their install() rules then fail configure with "no BUNDLE DESTINATION". We build
# a shared library, not app bundles, so force bundles off to keep them valid.
if((ET_BUILD_LLM OR ET_BUILD_TOKENIZER) AND APPLE)
    set(CMAKE_MACOSX_BUNDLE OFF CACHE BOOL "" FORCE)
    message(STATUS "Tokenizer build: CMAKE_MACOSX_BUNDLE forced OFF (sentencepiece tools)")

    # sentencepiece's src/CMakeLists.txt calls set_xcode_property() on its CLI
    # tools (spm_encode/decode/...) under `if(CMAKE_SYSTEM_NAME STREQUAL "iOS")`,
    # but THIS sentencepiece version never defines that macro — so an iOS build
    # dies at configure with `Unknown CMake command "set_xcode_property"` (macOS
    # skips the block, which is why only iOS failed). The calls only set
    # PRODUCT_BUNDLE_IDENTIFIER on command-line tools we never ship, so define a
    # no-op macro (macros are global once defined, so it is in scope when
    # sentencepiece is processed inside add_subdirectory below).
    if(NOT COMMAND set_xcode_property)
        macro(set_xcode_property)
        endmacro()
        message(STATUS "LLM build: defined no-op set_xcode_property (sentencepiece iOS)")
    endif()
endif()

# The MLX delegate builds MLX from the backends/mlx/third-party/mlx submodule and
# FATAL_ERRORs at configure time if it is not initialized. FetchContent only pulls
# the submodules listed at clone time, and a pre-existing source checkout may not
# have it, so init it on demand (non-recursive — MLX pulls its own deps via CMake).
if(EXECUTORCH_BUILD_MLX)
    set(_mlx_submodule_dir "${executorch_SOURCE_DIR}/backends/mlx/third-party/mlx")
    if(NOT EXISTS "${_mlx_submodule_dir}/CMakeLists.txt")
        message(STATUS "MLX submodule missing, fetching it...")
        execute_process(
            COMMAND git submodule update --init backends/mlx/third-party/mlx
            WORKING_DIRECTORY ${executorch_SOURCE_DIR}
            RESULT_VARIABLE _mlx_submodule_result
        )
        if(NOT _mlx_submodule_result EQUAL 0
           OR NOT EXISTS "${_mlx_submodule_dir}/CMakeLists.txt")
            message(FATAL_ERROR
                "Failed to initialize the MLX submodule at ${_mlx_submodule_dir}.\n"
                "Run manually: cd ${executorch_SOURCE_DIR} && "
                "git submodule update --init backends/mlx/third-party/mlx")
        endif()
        message(STATUS "MLX submodule fetched successfully")
    else()
        message(STATUS "MLX submodule present at ${_mlx_submodule_dir}")
    endif()

    # MLX compiles Metal shaders (-> mlx.metallib) with the `metal` tool, which
    # Xcode 15+/26 ships as a SEPARATE downloadable "Metal Toolchain" component.
    # Without it the build dies deep in compilation with a cryptic
    # "cannot execute tool 'metal' due to missing Metal Toolchain". Pre-check and
    # fail fast with the exact fix.
    execute_process(
        COMMAND xcrun metal --version
        RESULT_VARIABLE _metal_check
        OUTPUT_QUIET ERROR_QUIET
    )
    if(NOT _metal_check EQUAL 0)
        message(FATAL_ERROR
            "MLX backend requires the Xcode Metal Toolchain, which is not "
            "installed (xcrun metal failed).\n"
            "Install it once with:\n"
            "  xcodebuild -downloadComponent MetalToolchain\n"
            "then rebuild. (Verify with: xcodebuild -showComponent MetalToolchain)")
    endif()
    message(STATUS "MLX: Metal Toolchain present")

    # backends/mlx/CMakeLists.txt compiles mlxdelegate with `-Werror` (its
    # _common_compile_options). mlxdelegate includes ExecuTorch core headers
    # (dim_order_util.h, tensor_util.h) that emit -Wshorten-64-to-32 warnings on
    # Xcode 26.5 / arm64-macOS, so -Werror turns them into hard errors. Our global
    # add_compile_options(-Wno-error) can't help because the target appends
    # -Werror AFTER it. Patch -Werror out of MLX's option list (idempotent).
    set(_mlx_cmakelists "${executorch_SOURCE_DIR}/backends/mlx/CMakeLists.txt")
    if(EXISTS "${_mlx_cmakelists}")
        file(READ "${_mlx_cmakelists}" _mlx_cml_content)
        string(FIND "${_mlx_cml_content}" "-Wall -Werror -Wno-deprecated-declarations" _mlx_werror_pos)
        if(NOT _mlx_werror_pos EQUAL -1)
            string(REPLACE
                "-Wall -Werror -Wno-deprecated-declarations"
                "-Wall -Wno-deprecated-declarations -Wno-shorten-64-to-32"
                _mlx_cml_content "${_mlx_cml_content}")
            file(WRITE "${_mlx_cmakelists}" "${_mlx_cml_content}")
            message(STATUS "MLX: patched -Werror out of backends/mlx/CMakeLists.txt")
        else()
            message(STATUS "MLX: -Werror already patched out of backends/mlx/CMakeLists.txt")
        endif()
    endif()

    # Patch MLX's metallib loader to honor the ET_MLX_METALLIB_PATH env var FIRST.
    # MLX bundles its Metal kernels as mlx.metallib and at runtime searches only
    # next to the loaded binary / a couple of Resources dirs / a compile-time
    # absolute path. Inside a sandboxed Flutter app the dylib lives in a generated
    # .framework and the native-assets bundler does not place the .metallib there,
    # so every search fails (MLXBackend init -> 0x23). We ship the metallib as a
    # Flutter data asset and point MLX at it via the env var, which our FFI
    # (et_llm_set_metallib_path) sets before model load. Idempotent string patch
    # into load_default_library() in device.cpp.
    set(_mlx_device_cpp
        "${_mlx_submodule_dir}/mlx/backend/metal/device.cpp")
    if(EXISTS "${_mlx_device_cpp}")
        file(READ "${_mlx_device_cpp}" _mlx_dev_content)
        string(FIND "${_mlx_dev_content}" "ET_MLX_METALLIB_PATH" _mlx_env_pos)
        if(_mlx_env_pos EQUAL -1)
            # Insert an env-var lookup as the first attempt inside
            # load_default_library(MTL::Device* device) { ... }
            string(REPLACE
                "MTL::Library* load_default_library(MTL::Device* device) {"
                "MTL::Library* load_default_library(MTL::Device* device) {\n  // ExecuTorch Flutter: explicit metallib path (sandboxed app bundles).\n  if (const char* _et_mtllib = std::getenv(\"ET_MLX_METALLIB_PATH\")) {\n    if (_et_mtllib[0] != '\\0') {\n      auto [_et_lib, _et_err] = load_library_from_path(device, _et_mtllib);\n      if (_et_lib) {\n        return _et_lib;\n      }\n    }\n  }"
                _mlx_dev_content "${_mlx_dev_content}")
            file(WRITE "${_mlx_device_cpp}" "${_mlx_dev_content}")
            message(STATUS "MLX: patched ET_MLX_METALLIB_PATH lookup into device.cpp")
        else()
            message(STATUS "MLX: ET_MLX_METALLIB_PATH lookup already patched into device.cpp")
        endif()
    else()
        message(WARNING "MLX device.cpp not found at ${_mlx_device_cpp}; metallib env override not applied")
    endif()
endif()

# The optimized CPU kernels (enabled for MLX, see above) build EigenBLAS from the
# kernels/optimized/third-party/eigen submodule and CMake-error ("No SOURCES
# given to target: eigen_blas") if it is not initialized. Same situation as the
# MLX submodule — init it on demand for pre-existing source checkouts.
if(EXECUTORCH_BUILD_KERNELS_OPTIMIZED)
    set(_eigen_submodule_dir "${executorch_SOURCE_DIR}/kernels/optimized/third-party/eigen")
    if(NOT EXISTS "${_eigen_submodule_dir}/blas/single.cpp")
        message(STATUS "Eigen submodule missing, fetching it...")
        execute_process(
            COMMAND git submodule update --init kernels/optimized/third-party/eigen
            WORKING_DIRECTORY ${executorch_SOURCE_DIR}
            RESULT_VARIABLE _eigen_submodule_result
        )
        if(NOT _eigen_submodule_result EQUAL 0
           OR NOT EXISTS "${_eigen_submodule_dir}/blas/single.cpp")
            message(FATAL_ERROR
                "Failed to initialize the Eigen submodule at ${_eigen_submodule_dir}.\n"
                "Run manually: cd ${executorch_SOURCE_DIR} && "
                "git submodule update --init kernels/optimized/third-party/eigen")
        endif()
        message(STATUS "Eigen submodule fetched successfully")
    else()
        message(STATUS "Eigen submodule present at ${_eigen_submodule_dir}")
    endif()
endif()

# Newer host toolchains (e.g. Xcode 26 clang) introduce warnings that ExecuTorch's
# older bundled third-party code (flatcc, etc.) trips with -Werror, failing an
# otherwise-valid source build. Relax -Werror for the whole subtree. add_compile_options
# is applied after CMAKE_C_FLAGS, so a trailing -Wno-error overrides third-party
# `set(CMAKE_C_FLAGS "... -Werror")`; FLATCC_ALLOW_WERROR=OFF also stops flatcc adding it.
set(FLATCC_ALLOW_WERROR OFF CACHE BOOL "Disable flatcc -Werror" FORCE)
add_compile_options(-Wno-error)

# Windows + Ninja: ExecuTorch builds the flatc/flatcc host compilers via
# ExternalProject and declares their BUILD_BYPRODUCTS WITHOUT the executable
# suffix (`<INSTALL_DIR>/bin/flatc`). On Windows the produced file is `flatc.exe`,
# so a Ninja build of the schema codegen (which depends on flatc.exe) fails with
# "flatc.exe ... missing and no known rule to make it". (The Visual Studio
# generator used target-level deps and didn't care; non-Windows exes have no
# suffix so the byproduct matched.) Append .exe to the byproducts so Ninja knows
# the rule produces them. Idempotent + CRLF-tolerant.
if(WIN32)
    set(_et_thirdparty_cml "${executorch_SOURCE_DIR}/third-party/CMakeLists.txt")
    if(EXISTS "${_et_thirdparty_cml}")
        file(READ "${_et_thirdparty_cml}" _et_tp_content)
        string(REGEX REPLACE
            "(/bin/flatcc?)(\r?\n)" "\\1.exe\\2"
            _et_tp_content "${_et_tp_content}")
        file(WRITE "${_et_thirdparty_cml}" "${_et_tp_content}")
        message(STATUS "Windows: patched flatc/flatcc BUILD_BYPRODUCTS with .exe (Ninja)")
    endif()
endif()

# Add ExecuTorch as subdirectory - now our variables are guaranteed to be set first
message(STATUS "Adding ExecuTorch as subdirectory...")
message(STATUS "  EXECUTORCH_BUILD_VULKAN: ${EXECUTORCH_BUILD_VULKAN}")
message(STATUS "  EXECUTORCH_BUILD_XNNPACK: ${EXECUTORCH_BUILD_XNNPACK}")
message(STATUS "  EXECUTORCH_BUILD_COREML: ${EXECUTORCH_BUILD_COREML}")
message(STATUS "  EXECUTORCH_BUILD_MPS: ${EXECUTORCH_BUILD_MPS}")
add_subdirectory(${executorch_SOURCE_DIR} ${executorch_BINARY_DIR})

# ============================================================================
# Set Include and Library Paths
# ============================================================================

set(EXECUTORCH_INCLUDE_DIRS
    ${executorch_SOURCE_DIR}
    ${executorch_SOURCE_DIR}/runtime/core
    ${executorch_SOURCE_DIR}/runtime/core/exec_aten
    ${executorch_SOURCE_DIR}/runtime/executor
    ${executorch_SOURCE_DIR}/extension/module
    ${executorch_SOURCE_DIR}/extension/data_loader
    ${executorch_SOURCE_DIR}/extension/tensor
    ${executorch_BINARY_DIR}
    CACHE PATH "ExecuTorch include directories"
)

set(EXECUTORCH_LIBRARY_DIRS "" CACHE PATH "ExecuTorch library directories (not used for source build)")

# For source builds, we link directly to targets
set(EXECUTORCH_LIBRARIES
    executorch
    extension_module_static
    extension_data_loader
    extension_tensor
)

# Op registration table. The MLX build swaps portable -> optimized: linking BOTH
# would double-register the aten::* ops (RegistrationAlreadyRegistered, 0x16).
# optimized_native_cpu_ops_lib registers optimized kernels and falls back to
# portable_kernels per-op, so portable_kernels is still linked as the impl source.
# Unlike the backend delegates, op libs do NOT self-apply whole-archive, so the
# static op-registration initializers must be force-loaded explicitly (same as
# quantized_ops_lib below) or generate() hits OperatorMissing (0x14).
if(EXECUTORCH_BUILD_KERNELS_OPTIMIZED AND TARGET optimized_native_cpu_ops_lib)
    list(APPEND EXECUTORCH_LIBRARIES optimized_native_cpu_ops_lib portable_kernels)
    executorch_target_link_options_shared_lib(optimized_native_cpu_ops_lib)
    message(STATUS "Using optimized CPU op kernels (optimized_native_cpu_ops_lib)")
else()
    list(APPEND EXECUTORCH_LIBRARIES portable_ops_lib portable_kernels)
endif()

# Extension libraries (conditionally linked if targets exist)
if(TARGET extension_flat_tensor)
    list(APPEND EXECUTORCH_LIBRARIES extension_flat_tensor)
endif()
if(TARGET extension_named_data_map)
    list(APPEND EXECUTORCH_LIBRARIES extension_named_data_map)
endif()

# Backend libraries
if(ET_BUILD_XNNPACK AND TARGET xnnpack_backend)
    list(APPEND EXECUTORCH_LIBRARIES xnnpack_backend)
endif()

if(ET_BUILD_COREML AND TARGET coremldelegate)
    list(APPEND EXECUTORCH_LIBRARIES coremldelegate)
endif()

if(ET_BUILD_MPS AND TARGET mpsdelegate)
    list(APPEND EXECUTORCH_LIBRARIES mpsdelegate)
endif()

# Metal delegate also needs the shared AOTI runtime (aoti_common) linked in.
if(ET_BUILD_METAL AND TARGET metal_backend)
    list(APPEND EXECUTORCH_LIBRARIES metal_backend)
    if(TARGET aoti_common)
        list(APPEND EXECUTORCH_LIBRARIES aoti_common)
    endif()
endif()

# MLX delegate. mlxdelegate self-applies whole-archive (its CMakeLists calls
# executorch_target_link_options_shared_lib) so its backend registration
# survives linking. The MLX library itself is only exposed at BUILD_INTERFACE on
# mlxdelegate, so the MLX symbols (mlx::core::*) must be linked explicitly.
if(ET_BUILD_MLX AND TARGET mlxdelegate)
    list(APPEND EXECUTORCH_LIBRARIES mlxdelegate)
    if(TARGET mlx)
        list(APPEND EXECUTORCH_LIBRARIES mlx)
    endif()
endif()

if(ET_BUILD_VULKAN AND TARGET vulkan_backend)
    list(APPEND EXECUTORCH_LIBRARIES vulkan_backend)
endif()

if(ET_BUILD_QNN AND TARGET qnn_backend)
    list(APPEND EXECUTORCH_LIBRARIES qnn_backend)
endif()

# LLM runner + tokenizers (text generation). Listed dependents-before-dependencies
# for correct static link order. Linking these targets also propagates their
# INTERFACE include dirs (executorch/extension/llm/runner + pytorch/tokenizers).
if(ET_BUILD_LLM)
    if(TARGET extension_llm_runner)
        list(APPEND EXECUTORCH_LIBRARIES extension_llm_runner)
    endif()
    if(TARGET extension_llm_sampler)
        list(APPEND EXECUTORCH_LIBRARIES extension_llm_sampler)
    endif()
    # Quantized op kernel library. Unlike the backend delegates, this op lib does NOT
    # self-apply whole-archive via its INTERFACE options, so we must call
    # executorch_target_link_options_shared_lib() on it (the same helper the upstream
    # gemma4 runner uses). Otherwise the linker strips its static kernel registrations
    # and generate() hits OperatorMissing (0x14) at the first decode step.
    if(TARGET quantized_ops_lib)
        list(APPEND EXECUTORCH_LIBRARIES quantized_ops_lib)
        executorch_target_link_options_shared_lib(quantized_ops_lib)
    endif()
endif()

# Tokenizers. ExecuTorch only adds this subdirectory as part of the LLM runner
# extension, but the standalone tokenizer FFI needs it without the runner, so
# add it directly when nothing else has.
if(ET_BUILD_TOKENIZER)
    if(NOT TARGET tokenizers)
        message(STATUS "Adding tokenizers subdirectory (standalone, no LLM runner)")
        add_subdirectory(
            ${executorch_SOURCE_DIR}/extension/llm/tokenizers
            ${CMAKE_BINARY_DIR}/tokenizers
            EXCLUDE_FROM_ALL
        )
    endif()
    if(TARGET tokenizers)
        list(APPEND EXECUTORCH_LIBRARIES tokenizers)
    else()
        message(FATAL_ERROR
            "ET_BUILD_TOKENIZER is ON but no 'tokenizers' target exists after "
            "adding ${executorch_SOURCE_DIR}/extension/llm/tokenizers.")
    endif()
    list(APPEND EXECUTORCH_INCLUDE_DIRS
        ${executorch_SOURCE_DIR}/extension/llm/tokenizers/include
    )
endif()

message(STATUS "ExecuTorch libraries: ${EXECUTORCH_LIBRARIES}")
