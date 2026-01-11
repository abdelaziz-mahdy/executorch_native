# download_prebuilt.cmake
# Downloads pre-built ExecuTorch FFI binaries from GitHub Releases
#
# In prebuilt mode, we download the already-compiled FFI library
# and skip building entirely. This is fast and requires no dependencies.

# ============================================================================
# Configuration
# ============================================================================

# GitHub repository for pre-built binaries
set(EXECUTORCH_PREBUILT_REPO "abdelaziz-mahdy/executorch_native" CACHE STRING "GitHub repo for pre-built binaries")
set(EXECUTORCH_PREBUILT_URL_BASE "https://github.com/${EXECUTORCH_PREBUILT_REPO}/releases/download")

# Determine archive extension based on platform
if(WIN32)
    set(_archive_ext "zip")
else()
    set(_archive_ext "tar.gz")
endif()

# Build the filename based on platform, arch, and variant
set(_filename "libexecutorch_ffi-${EXECUTORCH_PLATFORM}-${EXECUTORCH_ARCH}-${EXECUTORCH_VARIANT}.${_archive_ext}")
set(_url "${EXECUTORCH_PREBUILT_URL_BASE}/v${EXECUTORCH_VERSION}/${_filename}")

message(STATUS "--------------------------")
message(STATUS "Pre-built Download Configuration:")
message(STATUS "  Repository: ${EXECUTORCH_PREBUILT_REPO}")
message(STATUS "  Version: v${EXECUTORCH_VERSION}")
message(STATUS "  Platform: ${EXECUTORCH_PLATFORM}")
message(STATUS "  Architecture: ${EXECUTORCH_ARCH}")
message(STATUS "  Variant: ${EXECUTORCH_VARIANT}")
message(STATUS "  Filename: ${_filename}")
message(STATUS "  URL: ${_url}")
message(STATUS "--------------------------")

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
    message(STATUS "Using local pre-built: ${EXECUTORCH_INSTALL_DIR}")
else()
    message(STATUS "Downloading pre-built ExecuTorch FFI library...")

    # Use FetchContent to download and extract
    include(FetchContent)

    FetchContent_Declare(
        libexecutorch_prebuilt
        URL ${_url}
        DOWNLOAD_NO_EXTRACT FALSE
    )

    # Make available - this will download and extract
    FetchContent_MakeAvailable(libexecutorch_prebuilt)

    set(EXECUTORCH_INSTALL_DIR ${libexecutorch_prebuilt_SOURCE_DIR} CACHE PATH "Pre-built install directory" FORCE)
    message(STATUS "Pre-built ExecuTorch FFI extracted to: ${EXECUTORCH_INSTALL_DIR}")
endif()

# ============================================================================
# Verify Downloaded Content
# ============================================================================

# Check that the expected files exist
if(NOT EXISTS "${EXECUTORCH_INSTALL_DIR}/lib")
    message(FATAL_ERROR "Pre-built package missing lib/ directory: ${EXECUTORCH_INSTALL_DIR}")
endif()

if(NOT EXISTS "${EXECUTORCH_INSTALL_DIR}/include")
    message(WARNING "Pre-built package missing include/ directory (may be OK): ${EXECUTORCH_INSTALL_DIR}")
endif()

# List what we found
file(GLOB _prebuilt_libs "${EXECUTORCH_INSTALL_DIR}/lib/*")
message(STATUS "Found pre-built libraries:")
foreach(_lib ${_prebuilt_libs})
    message(STATUS "  - ${_lib}")
endforeach()
