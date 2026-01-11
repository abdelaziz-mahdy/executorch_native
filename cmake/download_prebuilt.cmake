# download_prebuilt.cmake
# Downloads pre-built ExecuTorch FFI binaries from GitHub Releases

# ============================================================================
# Configuration
# ============================================================================

# GitHub repository for pre-built binaries
# TODO: Update this to your actual repository
set(EXECUTORCH_PREBUILT_REPO "user/executorch_native" CACHE STRING "GitHub repo for pre-built binaries")
set(EXECUTORCH_PREBUILT_URL_BASE "https://github.com/${EXECUTORCH_PREBUILT_REPO}/releases/download")

# Build the filename based on platform, arch, and variant
set(_filename "libexecutorch_ffi-${EXECUTORCH_PLATFORM}-${EXECUTORCH_ARCH}-${EXECUTORCH_VARIANT}.tar.gz")
set(_url "${EXECUTORCH_PREBUILT_URL_BASE}/v${EXECUTORCH_VERSION}/${_filename}")

message(STATUS "Pre-built binary URL: ${_url}")

# ============================================================================
# Caching Support
# ============================================================================

if(DEFINED EXECUTORCH_CACHE_DIR AND NOT "${EXECUTORCH_CACHE_DIR}" STREQUAL "")
    if(NOT EXISTS "${EXECUTORCH_CACHE_DIR}")
        file(MAKE_DIRECTORY "${EXECUTORCH_CACHE_DIR}")
    endif()
    set(FETCHCONTENT_BASE_DIR
        "${EXECUTORCH_CACHE_DIR}/${EXECUTORCH_PLATFORM}/${EXECUTORCH_ARCH}"
        CACHE PATH "FetchContent cache directory" FORCE)
    message(STATUS "Using cache directory: ${FETCHCONTENT_BASE_DIR}")
endif()

# ============================================================================
# Download Pre-built Binary
# ============================================================================

# Check if we should skip download (for local development)
if(DEFINED ENV{EXECUTORCH_DISABLE_DOWNLOAD} OR EXECUTORCH_DISABLE_DOWNLOAD)
    if(NOT EXECUTORCH_INSTALL_DIR)
        message(FATAL_ERROR "EXECUTORCH_INSTALL_DIR must be set when download is disabled")
    endif()
    message(STATUS "Using local ExecuTorch: ${EXECUTORCH_INSTALL_DIR}")
else()
    message(STATUS "Downloading pre-built ExecuTorch...")

    # Try to download the pre-built binary
    FetchContent_Declare(
        libexecutorch_prebuilt
        URL ${_url}
        DOWNLOAD_NO_EXTRACT FALSE
    )

    # Make available - this will download and extract
    FetchContent_MakeAvailable(libexecutorch_prebuilt)

    set(EXECUTORCH_INSTALL_DIR ${libexecutorch_prebuilt_SOURCE_DIR})
    message(STATUS "Pre-built ExecuTorch extracted to: ${EXECUTORCH_INSTALL_DIR}")
endif()

# ============================================================================
# Set Include and Library Paths
# ============================================================================

set(EXECUTORCH_INCLUDE_DIRS
    ${EXECUTORCH_INSTALL_DIR}/include
    CACHE PATH "ExecuTorch include directories"
)

set(EXECUTORCH_LIBRARY_DIRS
    ${EXECUTORCH_INSTALL_DIR}/lib
    CACHE PATH "ExecuTorch library directories"
)

# Core libraries (always included)
set(EXECUTORCH_LIBRARIES
    executorch
    extension_module_static
    extension_data_loader
    extension_tensor
    portable_ops_lib
    portable_kernels
)

# Backend libraries
if(ET_BUILD_XNNPACK)
    list(APPEND EXECUTORCH_LIBRARIES xnnpack_backend)
endif()

if(ET_BUILD_COREML AND APPLE)
    list(APPEND EXECUTORCH_LIBRARIES coreml_backend)
endif()

if(ET_BUILD_MPS AND APPLE)
    list(APPEND EXECUTORCH_LIBRARIES mps_backend)
endif()

if(ET_BUILD_VULKAN)
    list(APPEND EXECUTORCH_LIBRARIES vulkan_backend)
endif()

if(ET_BUILD_QNN)
    list(APPEND EXECUTORCH_LIBRARIES qnn_backend)
endif()

message(STATUS "ExecuTorch libraries: ${EXECUTORCH_LIBRARIES}")
