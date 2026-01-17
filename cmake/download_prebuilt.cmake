# download_prebuilt.cmake
# Downloads pre-built ExecuTorch FFI binaries from GitHub Releases
#
# In prebuilt mode, we download the already-compiled FFI library
# and skip building entirely. This is fast and requires no dependencies.
#
# Features:
# - SHA256 hash verification for integrity
# - Cache busting: re-downloads if hash changes
# - Automatic cleanup of stale cached files

# ============================================================================
# Configuration
# ============================================================================

# GitHub repository for pre-built binaries
set(EXECUTORCH_PREBUILT_REPO "abdelaziz-mahdy/executorch_native" CACHE STRING
    "GitHub repo for pre-built binaries")
set(EXECUTORCH_PREBUILT_URL_BASE
    "https://github.com/${EXECUTORCH_PREBUILT_REPO}/releases/download")

# Determine archive extension based on platform
if(WIN32)
    set(_archive_ext "zip")
else()
    set(_archive_ext "tar.gz")
endif()

# Determine build type suffix (lowercase: release or debug)
string(TOLOWER "${CMAKE_BUILD_TYPE}" _build_type_lower)
if(NOT _build_type_lower)
    set(_build_type_lower "release")
endif()

# Build the filename based on platform, arch, variant, and build type
set(_filename
    "libexecutorch_ffi-${EXECUTORCH_PLATFORM}-${EXECUTORCH_ARCH}-${EXECUTORCH_VARIANT}-${_build_type_lower}.${_archive_ext}")
set(_base_url "${EXECUTORCH_PREBUILT_URL_BASE}/v${EXECUTORCH_PREBUILT_VERSION}/${_filename}")

# Generate cache-busting timestamp (changes each configure)
string(TIMESTAMP _cache_bust "%Y%m%d%H%M%S")
set(_url "${_base_url}?v=${_cache_bust}")
set(_hash_url "${_base_url}.sha256?v=${_cache_bust}")

message(STATUS "--------------------------")
message(STATUS "Pre-built Download Configuration:")
message(STATUS "  Repository: ${EXECUTORCH_PREBUILT_REPO}")
message(STATUS "  Version: v${EXECUTORCH_PREBUILT_VERSION}")
message(STATUS "  Platform: ${EXECUTORCH_PLATFORM}")
message(STATUS "  Architecture: ${EXECUTORCH_ARCH}")
message(STATUS "  Variant: ${EXECUTORCH_VARIANT}")
message(STATUS "  Build Type: ${_build_type_lower}")
message(STATUS "  Filename: ${_filename}")
message(STATUS "  URL: ${_url}")
message(STATUS "  Hash URL: ${_hash_url}")
message(STATUS "--------------------------")

# ============================================================================
# Hash Download and Verification Functions
# ============================================================================

# Download the SHA256 hash file from release
function(download_hash_file hash_url output_var)
    set(_hash_file "${CMAKE_BINARY_DIR}/_prebuilt_hash.sha256")

    # Always re-download hash file to check for updates (cache busting)
    file(DOWNLOAD
        "${hash_url}"
        "${_hash_file}"
        STATUS _download_status
        TIMEOUT 30
    )

    list(GET _download_status 0 _status_code)
    if(NOT _status_code EQUAL 0)
        message(WARNING "Failed to download hash file: ${hash_url}")
        message(WARNING "  Status: ${_download_status}")
        set(${output_var} "" PARENT_SCOPE)
        return()
    endif()

    # Read the hash from the file (format: "hash  filename" or just "hash")
    file(READ "${_hash_file}" _hash_content)
    string(STRIP "${_hash_content}" _hash_content)

    # Extract just the hash (first 64 characters, SHA256)
    string(SUBSTRING "${_hash_content}" 0 64 _expected_hash)
    string(TOLOWER "${_expected_hash}" _expected_hash)

    message(STATUS "Expected SHA256: ${_expected_hash}")
    set(${output_var} "${_expected_hash}" PARENT_SCOPE)
endfunction()

# Compute SHA256 hash of a local file
function(compute_file_hash file_path output_var)
    if(NOT EXISTS "${file_path}")
        set(${output_var} "" PARENT_SCOPE)
        return()
    endif()

    file(SHA256 "${file_path}" _computed_hash)
    string(TOLOWER "${_computed_hash}" _computed_hash)
    set(${output_var} "${_computed_hash}" PARENT_SCOPE)
endfunction()

# ============================================================================
# Caching Support with Hash-Based Invalidation
# ============================================================================

if(DEFINED EXECUTORCH_CACHE_DIR AND NOT "${EXECUTORCH_CACHE_DIR}" STREQUAL "")
    if(NOT EXISTS "${EXECUTORCH_CACHE_DIR}")
        file(MAKE_DIRECTORY "${EXECUTORCH_CACHE_DIR}")
    endif()
    set(_cache_base_dir "${EXECUTORCH_CACHE_DIR}")
else()
    set(_cache_base_dir "${CMAKE_BINARY_DIR}/_deps")
endif()

# Cache directory includes version for cache busting across versions
set(_cache_dir
    "${_cache_base_dir}/prebuilt-${EXECUTORCH_PREBUILT_VERSION}-${EXECUTORCH_PLATFORM}-${EXECUTORCH_ARCH}")
set(FETCHCONTENT_BASE_DIR "${_cache_dir}" CACHE PATH
    "FetchContent cache directory" FORCE)
message(STATUS "Cache directory: ${FETCHCONTENT_BASE_DIR}")

# ============================================================================
# Download Pre-built Binary with Hash Verification
# ============================================================================

# Check if we should skip download (for local development)
if(DEFINED ENV{EXECUTORCH_DISABLE_DOWNLOAD} OR EXECUTORCH_DISABLE_DOWNLOAD)
    if(NOT EXECUTORCH_INSTALL_DIR)
        message(FATAL_ERROR
            "EXECUTORCH_INSTALL_DIR must be set when download is disabled")
    endif()
    message(STATUS "Using local pre-built: ${EXECUTORCH_INSTALL_DIR}")
else()
    # Download expected hash first (for cache busting)
    download_hash_file("${_hash_url}" _expected_hash)

    # Check if we have a valid cached version
    set(_hash_cache_file "${_cache_dir}/.cached_hash")
    set(_needs_download TRUE)

    if(EXISTS "${_hash_cache_file}" AND NOT "${_expected_hash}" STREQUAL "")
        file(READ "${_hash_cache_file}" _cached_hash)
        string(STRIP "${_cached_hash}" _cached_hash)

        if("${_cached_hash}" STREQUAL "${_expected_hash}")
            # Hash matches, check if extracted directory exists
            set(_extracted_dir "${_cache_dir}/libexecutorch_prebuilt-src")
            if(EXISTS "${_extracted_dir}/lib")
                message(STATUS "Using cached pre-built (hash verified)")
                set(_needs_download FALSE)
                set(EXECUTORCH_INSTALL_DIR "${_extracted_dir}" CACHE PATH
                    "Pre-built install directory" FORCE)
            endif()
        else()
            # Hash mismatch - need to re-download (cache busting!)
            message(STATUS "Hash mismatch detected - re-downloading")
            message(STATUS "  Cached: ${_cached_hash}")
            message(STATUS "  Expected: ${_expected_hash}")
            # Clean up old cached files
            file(REMOVE_RECURSE "${_cache_dir}/libexecutorch_prebuilt-src")
            file(REMOVE_RECURSE "${_cache_dir}/libexecutorch_prebuilt-subbuild")
            file(REMOVE_RECURSE "${_cache_dir}/libexecutorch_prebuilt-build")
        endif()
    endif()

    if(_needs_download)
        message(STATUS "Downloading pre-built ExecuTorch FFI library...")

        # Use FetchContent to download and extract
        include(FetchContent)

        # If we have an expected hash, use it for verification
        if(NOT "${_expected_hash}" STREQUAL "")
            FetchContent_Declare(
                libexecutorch_prebuilt
                URL ${_url}
                URL_HASH SHA256=${_expected_hash}
                DOWNLOAD_NO_EXTRACT FALSE
            )
        else()
            # No hash available, download without verification (with warning)
            message(WARNING
                "No hash file available - downloading without verification")
            FetchContent_Declare(
                libexecutorch_prebuilt
                URL ${_url}
                DOWNLOAD_NO_EXTRACT FALSE
            )
        endif()

        # Make available - this will download and extract
        FetchContent_MakeAvailable(libexecutorch_prebuilt)

        set(EXECUTORCH_INSTALL_DIR "${libexecutorch_prebuilt_SOURCE_DIR}"
            CACHE PATH "Pre-built install directory" FORCE)
        message(STATUS
            "Pre-built ExecuTorch FFI extracted to: ${EXECUTORCH_INSTALL_DIR}")

        # Save hash to cache file for future runs
        if(NOT "${_expected_hash}" STREQUAL "")
            file(WRITE "${_hash_cache_file}" "${_expected_hash}")
        endif()
    endif()
endif()

# ============================================================================
# Verify Downloaded Content
# ============================================================================

# Check that the expected files exist
if(NOT EXISTS "${EXECUTORCH_INSTALL_DIR}/lib")
    message(FATAL_ERROR
        "Pre-built package missing lib/ directory: ${EXECUTORCH_INSTALL_DIR}")
endif()

if(NOT EXISTS "${EXECUTORCH_INSTALL_DIR}/include")
    message(WARNING
        "Pre-built package missing include/ directory: ${EXECUTORCH_INSTALL_DIR}")
endif()

# Platform-specific library verification
if(WIN32)
    if(NOT EXISTS "${EXECUTORCH_INSTALL_DIR}/lib/executorch_ffi.dll")
        message(FATAL_ERROR
            "Pre-built package missing DLL: ${EXECUTORCH_INSTALL_DIR}/lib/executorch_ffi.dll")
    endif()
    message(STATUS "Found Windows DLL: ${EXECUTORCH_INSTALL_DIR}/lib/executorch_ffi.dll")
elseif(APPLE)
    file(GLOB _dylibs "${EXECUTORCH_INSTALL_DIR}/lib/*.dylib")
    if(NOT _dylibs)
        message(FATAL_ERROR
            "Pre-built package missing dylib files in: ${EXECUTORCH_INSTALL_DIR}/lib/")
    endif()
else()
    file(GLOB _sos "${EXECUTORCH_INSTALL_DIR}/lib/*.so*")
    if(NOT _sos)
        message(FATAL_ERROR
            "Pre-built package missing .so files in: ${EXECUTORCH_INSTALL_DIR}/lib/")
    endif()
endif()

# List what we found
file(GLOB _prebuilt_libs "${EXECUTORCH_INSTALL_DIR}/lib/*")
message(STATUS "Found pre-built libraries:")
foreach(_lib ${_prebuilt_libs})
    message(STATUS "  - ${_lib}")
endforeach()
