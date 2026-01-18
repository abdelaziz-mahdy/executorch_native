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
set(executorch_BINARY_DIR ${CMAKE_BINARY_DIR}/_deps/executorch_fetch-build)

# ExecuTorch build options (must be set before FetchContent_MakeAvailable)
set(EXECUTORCH_BUILD_HOST_TARGETS ON CACHE BOOL "Build host targets" FORCE)
set(EXECUTORCH_BUILD_FLATC ON CACHE BOOL "Build flatc" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_MODULE ON CACHE BOOL "Build extension module" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR ON CACHE BOOL "Build flat tensor extension" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP ON CACHE BOOL "Build named data map extension" FORCE)
set(EXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL ON CACHE BOOL "Build runner util extension" FORCE)
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

if(ET_BUILD_XNNPACK)
    set(EXECUTORCH_BUILD_XNNPACK ON CACHE BOOL "Build XNNPACK backend" FORCE)
else()
    set(EXECUTORCH_BUILD_XNNPACK OFF CACHE BOOL "Build XNNPACK backend" FORCE)
endif()

if(ET_BUILD_COREML AND APPLE)
    set(EXECUTORCH_BUILD_COREML ON CACHE BOOL "Build CoreML backend" FORCE)
else()
    set(EXECUTORCH_BUILD_COREML OFF CACHE BOOL "Build CoreML backend" FORCE)
endif()

if(ET_BUILD_MPS AND APPLE)
    set(EXECUTORCH_BUILD_MPS ON CACHE BOOL "Build MPS backend" FORCE)
else()
    set(EXECUTORCH_BUILD_MPS OFF CACHE BOOL "Build MPS backend" FORCE)
endif()

# Vulkan requires glslc compiler - check availability when requested
if(ET_BUILD_VULKAN)
    find_program(GLSLC_EXECUTABLE glslc
        HINTS
            $ENV{VULKAN_SDK}/bin
            /usr/bin
            /usr/local/bin
    )
    if(NOT GLSLC_EXECUTABLE)
        message(WARNING "glslc not found - Vulkan backend requires glslc compiler")
        message(WARNING "Install Vulkan SDK or set VULKAN_SDK environment variable")
        message(WARNING "Disabling Vulkan backend")
        set(EXECUTORCH_BUILD_VULKAN OFF CACHE BOOL "Build Vulkan backend" FORCE)
    else()
        message(STATUS "Found glslc: ${GLSLC_EXECUTABLE}")
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

set(_original_python ${PYTHON_EXECUTABLE})
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

set(_vulkan_submodules
    backends/vulkan/runtime/vk_api/volk
    backends/vulkan/runtime/vk_api/Vulkan-Headers
)

if(EXISTS "${executorch_SOURCE_DIR}/CMakeLists.txt")
    message(STATUS "ExecuTorch v${EXECUTORCH_VERSION} already present at ${executorch_SOURCE_DIR}")

    # If Vulkan is requested but submodules are missing, fetch them separately
    if(ET_BUILD_VULKAN AND GLSLC_EXECUTABLE)
        set(_vulkan_submodules_missing FALSE)
        foreach(_submod ${_vulkan_submodules})
            if(NOT EXISTS "${executorch_SOURCE_DIR}/${_submod}/CMakeLists.txt")
                set(_vulkan_submodules_missing TRUE)
                break()
            endif()
        endforeach()

        if(_vulkan_submodules_missing)
            message(STATUS "Vulkan submodules missing, fetching them...")
            execute_process(
                COMMAND git submodule update --init --recursive
                    backends/vulkan/runtime/vk_api/volk
                    backends/vulkan/runtime/vk_api/Vulkan-Headers
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
    if(ET_BUILD_VULKAN AND GLSLC_EXECUTABLE)
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
    portable_ops_lib
    portable_kernels
)

# Backend libraries
if(ET_BUILD_XNNPACK AND TARGET xnnpack_backend)
    list(APPEND EXECUTORCH_LIBRARIES xnnpack_backend)
endif()

if(ET_BUILD_COREML AND TARGET coreml_backend)
    list(APPEND EXECUTORCH_LIBRARIES coreml_backend)
endif()

if(ET_BUILD_MPS AND TARGET mps_backend)
    list(APPEND EXECUTORCH_LIBRARIES mps_backend)
endif()

if(ET_BUILD_VULKAN AND TARGET vulkan_backend)
    list(APPEND EXECUTORCH_LIBRARIES vulkan_backend)
endif()

if(ET_BUILD_QNN AND TARGET qnn_backend)
    list(APPEND EXECUTORCH_LIBRARIES qnn_backend)
endif()

message(STATUS "ExecuTorch libraries: ${EXECUTORCH_LIBRARIES}")
