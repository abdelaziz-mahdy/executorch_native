cmake_minimum_required(VERSION 3.18)

project(executorch_ffi VERSION 2.0.0 LANGUAGES CXX C)

# ============================================================================
# Build Options
# ============================================================================

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ----------------------------------------------------------------------------
# Compiler cache (ccache / sccache)
#
# Speeds up rebuilds dramatically - especially in CI, where a wrapper-only
# change otherwise recompiles all of ExecuTorch from scratch. When a compiler
# cache is found it is applied to both this wrapper and the ExecuTorch subbuild
# (CMAKE_*_COMPILER_LAUNCHER propagates to FetchContent subprojects). Harmless
# when absent, when explicitly overridden, or with multi-config generators
# (Xcode / Visual Studio ignore the launcher).
# ----------------------------------------------------------------------------
if(NOT DEFINED CMAKE_CXX_COMPILER_LAUNCHER)
    find_program(EXECUTORCH_FFI_COMPILER_CACHE NAMES ccache sccache)
    if(EXECUTORCH_FFI_COMPILER_CACHE)
        message(STATUS "executorch_ffi: using compiler cache ${EXECUTORCH_FFI_COMPILER_CACHE}")
        set(CMAKE_C_COMPILER_LAUNCHER "${EXECUTORCH_FFI_COMPILER_CACHE}")
        set(CMAKE_CXX_COMPILER_LAUNCHER "${EXECUTORCH_FFI_COMPILER_CACHE}")
    endif()
endif()

# ExecuTorch source version (upstream PyTorch ExecuTorch version)
if(NOT DEFINED EXECUTORCH_VERSION OR "${EXECUTORCH_VERSION}" STREQUAL "")
    set(EXECUTORCH_VERSION "1.3.1" CACHE STRING "ExecuTorch source version" FORCE)
else()
    set(EXECUTORCH_VERSION "${EXECUTORCH_VERSION}" CACHE STRING "ExecuTorch source version" FORCE)
endif()

# Prebuilt release version (our release tag for prebuilt downloads)
if(NOT DEFINED EXECUTORCH_PREBUILT_VERSION OR "${EXECUTORCH_PREBUILT_VERSION}" STREQUAL "")
    set(EXECUTORCH_PREBUILT_VERSION "1.3.1.3" CACHE STRING "Prebuilt release version" FORCE)
else()
    set(EXECUTORCH_PREBUILT_VERSION "${EXECUTORCH_PREBUILT_VERSION}" CACHE STRING "Prebuilt release version" FORCE)
endif()

# Build mode: "prebuilt" (default) or "source"
if(NOT EXECUTORCH_BUILD_MODE)
    set(EXECUTORCH_BUILD_MODE "prebuilt")
endif()

message(STATUS "============================================================")
message(STATUS "ExecuTorch Native FFI Build")
message(STATUS "============================================================")
message(STATUS "  FFI Version: ${PROJECT_VERSION}")
message(STATUS "  ExecuTorch Version: ${EXECUTORCH_VERSION}")
message(STATUS "  Prebuilt Version: ${EXECUTORCH_PREBUILT_VERSION}")
message(STATUS "  Build Mode: ${EXECUTORCH_BUILD_MODE}")
message(STATUS "============================================================")

# Backend configuration options
option(ET_BUILD_XNNPACK "Build with XNNPACK backend" ON)
option(ET_BUILD_COREML "Build with CoreML backend" OFF)
option(ET_BUILD_MPS "Build with MPS backend" OFF)
option(ET_BUILD_METAL "Build with Metal backend (macOS)" OFF)
option(ET_BUILD_VULKAN "Build with Vulkan backend" OFF)
option(ET_BUILD_QNN "Build with QNN backend" OFF)
# LLM (text generation) runner FFI. OFF by default so existing tensor-only
# prebuilt builds are unaffected. Requires a source build (or a prebuilt that
# bundles libextension_llm_runner + libtokenizers) — see build_from_source.cmake.
option(ET_BUILD_LLM "Build with LLM (text generation) runner FFI" OFF)
option(ET_BUILD_LLM_HARNESS "Build the standalone LLM validation harness" OFF)

# Platform-specific defaults.
# CoreML is enabled on all Apple platforms. The deprecated MPS backend is
# replaced by the new Metal backend, which is macOS-desktop-only (not iOS).
# These default ON for Apple but respect an explicit OFF (the Flutter hook
# passes ET_BUILD_* values derived from the `backends:` list — e.g. an
# xnnpack-only LLM build must be able to keep CoreML/Metal off).
if(APPLE)
    if(ET_BUILD_COREML)
        set(ET_BUILD_COREML ON CACHE BOOL "Build with CoreML backend" FORCE)
    endif()
    if(ET_BUILD_METAL AND CMAKE_SYSTEM_NAME STREQUAL "Darwin"
       AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64")
        set(ET_BUILD_METAL ON CACHE BOOL "Build with Metal backend" FORCE)
    endif()
endif()

# ============================================================================
# CMake Policies
# ============================================================================

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
    cmake_policy(SET CMP0135 NEW)
endif()

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.30.0")
    cmake_policy(SET CMP0169 OLD)
endif()

include(FetchContent)

# ============================================================================
# Build Variant String (for pre-built binary selection)
# ============================================================================

set(_variant_parts "")
if(ET_BUILD_XNNPACK)
    list(APPEND _variant_parts "xnnpack")
endif()
if(ET_BUILD_COREML)
    list(APPEND _variant_parts "coreml")
endif()
if(ET_BUILD_MPS)
    list(APPEND _variant_parts "mps")
endif()
if(ET_BUILD_METAL)
    list(APPEND _variant_parts "metal")
endif()
if(ET_BUILD_VULKAN)
    list(APPEND _variant_parts "vulkan")
endif()
if(ET_BUILD_QNN)
    list(APPEND _variant_parts "qnn")
endif()

string(JOIN "-" EXECUTORCH_VARIANT ${_variant_parts})
message(STATUS "  Backend Variant: ${EXECUTORCH_VARIANT}")

# ============================================================================
# Platform Detection
# ============================================================================

if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    set(EXECUTORCH_PLATFORM "android")
    set(EXECUTORCH_ARCH ${ANDROID_ABI})
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(EXECUTORCH_PLATFORM "macos")
    if(CMAKE_OSX_ARCHITECTURES)
        set(EXECUTORCH_ARCH ${CMAKE_OSX_ARCHITECTURES})
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64")
        set(EXECUTORCH_ARCH "arm64")
    else()
        set(EXECUTORCH_ARCH "x64")
    endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Detect iOS simulator vs device based on SDK
    # CMAKE_OSX_SYSROOT will be something like ".../iPhoneSimulator.sdk" or ".../iPhoneOS.sdk"
    if(CMAKE_OSX_SYSROOT MATCHES "Simulator")
        set(EXECUTORCH_PLATFORM "ios-simulator")
        # iOS simulators can be arm64 (Apple Silicon) or x86_64 (Intel Mac)
        if(CMAKE_OSX_ARCHITECTURES)
            set(EXECUTORCH_ARCH ${CMAKE_OSX_ARCHITECTURES})
        elseif(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "arm64")
            set(EXECUTORCH_ARCH "arm64")
        else()
            set(EXECUTORCH_ARCH "x64")
        endif()
    else()
        set(EXECUTORCH_PLATFORM "ios")
        set(EXECUTORCH_ARCH "arm64")
    endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(EXECUTORCH_PLATFORM "linux")
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
        set(EXECUTORCH_ARCH "arm64")
    else()
        set(EXECUTORCH_ARCH "x64")
    endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(EXECUTORCH_PLATFORM "windows")
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64")
        set(EXECUTORCH_ARCH "arm64")
    else()
        set(EXECUTORCH_ARCH "x64")
    endif()
else()
    message(FATAL_ERROR "Unsupported platform: ${CMAKE_SYSTEM_NAME}")
endif()

message(STATUS "  Platform: ${EXECUTORCH_PLATFORM}")
message(STATUS "  Architecture: ${EXECUTORCH_ARCH}")

# ============================================================================
# ExecuTorch Setup (Pre-built or Source)
# ============================================================================

if(EXECUTORCH_BUILD_MODE STREQUAL "prebuilt")
    # The LLM runner is not in the prebuilt binaries yet. Fail fast with a clear
    # message rather than producing a library missing the et_llm_* symbols.
    if(ET_BUILD_LLM)
        message(FATAL_ERROR
            "ET_BUILD_LLM=ON requires a source or local build — the prebuilt "
            "binaries do not yet bundle the LLM runner (extension_llm_runner + "
            "tokenizers). Rebuild with EXECUTORCH_BUILD_MODE=source, e.g.:\n"
            "  EXECUTORCH_BUILD_MODE=source EXECUTORCH_BUILD_LLM=ON flutter run -d macos")
    endif()

    # Download pre-built FFI library - no compilation needed
    include(cmake/download_prebuilt.cmake)

    # In prebuilt mode, we just copy the downloaded library to install location
    # The prebuilt tarball already contains lib/ and include/
    message(STATUS "Using pre-built FFI library from: ${EXECUTORCH_INSTALL_DIR}")

    # Create a custom target that just installs the prebuilt files
    add_custom_target(${PROJECT_NAME} ALL
        COMMENT "Using pre-built executorch_ffi library"
    )

    # Install prebuilt library and headers
    install(DIRECTORY ${EXECUTORCH_INSTALL_DIR}/lib/
        DESTINATION lib
        FILES_MATCHING
        PATTERN "*.so*"
        PATTERN "*.dylib*"
        PATTERN "*.dll"
        PATTERN "*.a"
        PATTERN "*.lib"
    )

    install(DIRECTORY ${EXECUTORCH_INSTALL_DIR}/include/
        DESTINATION include
        FILES_MATCHING PATTERN "*.h"
    )

    # Install MoltenVK ICD files if present (for macOS Vulkan variants)
    if(EXISTS "${EXECUTORCH_INSTALL_DIR}/share/vulkan/icd.d")
        install(DIRECTORY ${EXECUTORCH_INSTALL_DIR}/share/
            DESTINATION share
        )
        message(STATUS "Installing MoltenVK ICD files")
    endif()

    message(STATUS "============================================================")
    return()  # Skip the rest of CMakeLists.txt for prebuilt mode
endif()

# ============================================================================
# Source Build Mode - Build from source
# ============================================================================

include(cmake/build_from_source.cmake)

# ============================================================================
# Build FFI Library
# ============================================================================

set(SOURCES
    src/executorch_ffi.cpp
)

set(HEADERS
    src/executorch_ffi.h
)

# LLM runner FFI is compiled only when enabled (keeps tensor-only builds intact).
if(ET_BUILD_LLM)
    list(APPEND SOURCES src/executorch_llm_ffi.cpp)
    list(APPEND HEADERS src/executorch_llm_ffi.h)
    message(STATUS "  LLM runner FFI: ENABLED")
endif()

add_library(${PROJECT_NAME} SHARED ${SOURCES} ${HEADERS})

# Export definition
target_compile_definitions(${PROJECT_NAME} PRIVATE EXECUTORCH_FFI_EXPORTS)

# Include directories
target_include_directories(${PROJECT_NAME} PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
    $<INSTALL_INTERFACE:include>
)

target_include_directories(${PROJECT_NAME} PRIVATE
    ${EXECUTORCH_INCLUDE_DIRS}
)

# Link against ExecuTorch
target_link_directories(${PROJECT_NAME} PRIVATE ${EXECUTORCH_LIBRARY_DIRS})
target_link_libraries(${PROJECT_NAME} PRIVATE ${EXECUTORCH_LIBRARIES})

# Note: Backend delegates (CoreML, MPS, Vulkan, QNN) require whole-archive linking
# to ensure static initializers for register_backend() are not stripped by the linker.
# This is handled AUTOMATICALLY by upstream ExecuTorch - each backend target calls
# executorch_target_link_options_shared_lib() in its own CMakeLists.txt, which adds
# INTERFACE link options (--whole-archive / -force_load / /WHOLEARCHIVE) to the target.
# When we link against these targets via target_link_libraries above, the whole-archive
# flags are inherited automatically. No manual whole-archive handling needed here.

# Backend compile definitions
target_compile_definitions(${PROJECT_NAME} PRIVATE
    ET_BUILD_XNNPACK=$<BOOL:${ET_BUILD_XNNPACK}>
    ET_BUILD_COREML=$<BOOL:${ET_BUILD_COREML}>
    ET_BUILD_MPS=$<BOOL:${ET_BUILD_MPS}>
    ET_BUILD_METAL=$<BOOL:${ET_BUILD_METAL}>
    ET_BUILD_VULKAN=$<BOOL:${ET_BUILD_VULKAN}>
    ET_BUILD_QNN=$<BOOL:${ET_BUILD_QNN}>
    ET_BUILD_LLM=$<BOOL:${ET_BUILD_LLM}>
)

# ============================================================================
# Platform-Specific Settings
# ============================================================================

if(APPLE)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        FRAMEWORK FALSE
        MACOSX_RPATH TRUE
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_NAME_DIR "@rpath"
        # @loader_path allows dlopen() within this library to find sibling
        # libraries (e.g., libMoltenVK.dylib for Vulkan on macOS)
        INSTALL_RPATH "@loader_path"
    )
    set(CMAKE_CXX_VISIBILITY_PRESET hidden)
    set(CMAKE_C_VISIBILITY_PRESET hidden)
    set(CMAKE_VISIBILITY_INLINES_HIDDEN YES)

    find_library(FOUNDATION_FRAMEWORK Foundation)
    find_library(ACCELERATE_FRAMEWORK Accelerate)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        ${FOUNDATION_FRAMEWORK}
        ${ACCELERATE_FRAMEWORK}
    )

elseif(WIN32)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        WINDOWS_EXPORT_ALL_SYMBOLS OFF
    )

elseif(ANDROID)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        LIBRARY_OUTPUT_NAME "executorch_ffi"
        # $ORIGIN allows dlopen() within this library to find sibling
        # shared libraries in the same directory
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "$ORIGIN"
    )
    target_link_libraries(${PROJECT_NAME} PRIVATE log android)

elseif(UNIX AND NOT APPLE)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        LIBRARY_OUTPUT_NAME "executorch_ffi"
        # $ORIGIN allows dlopen() within this library to find sibling
        # shared libraries in the same directory
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "$ORIGIN"
    )
    target_link_libraries(${PROJECT_NAME} PRIVATE pthread dl)
endif()

# ============================================================================
# 16KB Page Size Alignment
# ============================================================================
# Required for Android 15+ devices and beneficial for ARM64 platforms.
# - Android: Required by Google Play for 16KB page size support
# - iOS/macOS ARM64: Already uses 16KB pages natively
# - Linux ARM64: Some distros use 16KB/64KB pages
# - x64 platforms: Doesn't hurt, provides future compatibility

if(NOT WIN32)
    # Use max-page-size linker flag for ELF binaries (Linux, Android)
    # Apple platforms use different linker but ARM64 is already 16KB aligned
    if(CMAKE_SYSTEM_NAME STREQUAL "Android" OR (UNIX AND NOT APPLE))
        target_link_options(${PROJECT_NAME} PRIVATE "-Wl,-z,max-page-size=16384")
        message(STATUS "  16KB page alignment: enabled (ELF)")
    elseif(APPLE)
        # Apple ARM64 already uses 16KB pages by default
        # For Intel Macs, this ensures compatibility
        target_link_options(${PROJECT_NAME} PRIVATE "-Wl,-segalign,0x4000")
        message(STATUS "  16KB page alignment: enabled (Mach-O)")
    endif()
endif()

# ============================================================================
# LLM Validation Harness (optional, Phase 1)
# ============================================================================
# Standalone executable that streams generation to stdout to validate the LLM
# runner end-to-end without Dart. Links the FFI shared library.
if(ET_BUILD_LLM AND ET_BUILD_LLM_HARNESS)
    add_executable(llm_harness test/llm_harness.cpp)
    target_include_directories(llm_harness PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
    target_link_libraries(llm_harness PRIVATE ${PROJECT_NAME})
    message(STATUS "  LLM harness: ENABLED (target: llm_harness)")
endif()

# ============================================================================
# Install Rules
# ============================================================================

# Install rules - put everything in lib/ for consistency across platforms
# (Windows DLLs typically go to bin/, but we use lib/ for native assets uniformity)
install(TARGETS ${PROJECT_NAME}
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION lib
)

install(FILES ${HEADERS} DESTINATION include)

message(STATUS "============================================================")
