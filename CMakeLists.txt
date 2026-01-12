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

# ExecuTorch source version (upstream PyTorch ExecuTorch version)
if(NOT DEFINED EXECUTORCH_VERSION OR "${EXECUTORCH_VERSION}" STREQUAL "")
    set(EXECUTORCH_VERSION "1.0.1" CACHE STRING "ExecuTorch source version" FORCE)
else()
    set(EXECUTORCH_VERSION "${EXECUTORCH_VERSION}" CACHE STRING "ExecuTorch source version" FORCE)
endif()

# Prebuilt release version (our release tag for prebuilt downloads)
if(NOT DEFINED EXECUTORCH_PREBUILT_VERSION OR "${EXECUTORCH_PREBUILT_VERSION}" STREQUAL "")
    set(EXECUTORCH_PREBUILT_VERSION "1.0.1.3" CACHE STRING "Prebuilt release version" FORCE)
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
option(ET_BUILD_VULKAN "Build with Vulkan backend" OFF)
option(ET_BUILD_QNN "Build with QNN backend" OFF)

# Platform-specific defaults
if(APPLE)
    set(ET_BUILD_COREML ON CACHE BOOL "Build with CoreML backend" FORCE)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64")
        set(ET_BUILD_MPS ON CACHE BOOL "Build with MPS backend" FORCE)
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
    set(EXECUTORCH_PLATFORM "ios")
    set(EXECUTORCH_ARCH "arm64")
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

# Backend compile definitions
target_compile_definitions(${PROJECT_NAME} PRIVATE
    ET_BUILD_XNNPACK=$<BOOL:${ET_BUILD_XNNPACK}>
    ET_BUILD_COREML=$<BOOL:${ET_BUILD_COREML}>
    ET_BUILD_MPS=$<BOOL:${ET_BUILD_MPS}>
    ET_BUILD_VULKAN=$<BOOL:${ET_BUILD_VULKAN}>
    ET_BUILD_QNN=$<BOOL:${ET_BUILD_QNN}>
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
    )
    target_link_libraries(${PROJECT_NAME} PRIVATE log android)

elseif(UNIX AND NOT APPLE)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        LIBRARY_OUTPUT_NAME "executorch_ffi"
    )
    target_link_libraries(${PROJECT_NAME} PRIVATE pthread dl)
endif()

# ============================================================================
# Install Rules
# ============================================================================

install(TARGETS ${PROJECT_NAME}
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)

install(FILES ${HEADERS} DESTINATION include)

message(STATUS "============================================================")
