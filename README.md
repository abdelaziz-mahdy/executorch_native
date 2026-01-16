# ExecuTorch Native FFI

C/C++ FFI wrapper for ExecuTorch, designed for use with Flutter/Dart via dart:ffi.

## Versioning

This project uses a 4-part version scheme: `X.Y.Z.W`

- **X.Y.Z** - ExecuTorch version (e.g., `1.0.1`)
- **W** - Build iteration for this ExecuTorch version (e.g., `1`, `2`, `3`)

Example: `v1.0.1.6` means ExecuTorch 1.0.1, sixth build iteration.

When ExecuTorch releases a new version, the first three numbers update and W resets to 1.

## Overview

This repository provides:
- **C FFI interface** (`src/executorch_ffi.h`) for cross-platform bindings
- **Pre-built binaries** for all major platforms (via GitHub Releases)
- **Build-from-source** option for custom configurations

## Pre-built Binaries

### Naming Pattern

```
libexecutorch_ffi-{platform}-{arch}-{backends}-{build_type}.{ext}
```

| Component | Values |
|-----------|--------|
| `platform` | `macos`, `ios`, `ios-simulator`, `linux`, `windows`, `android` |
| `arch` | `arm64`, `x86_64`, `x64`, `arm64-v8a` |
| `backends` | `xnnpack`, `xnnpack-coreml`, `xnnpack-mps`, `xnnpack-coreml-mps` |
| `build_type` | `release`, `debug` |
| `ext` | `.tar.gz` (Unix), `.zip` (Windows) |

### Current Release Variants (v1.0.1.6)

#### macOS
| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-macos-arm64-xnnpack-{release,debug}.tar.gz` | Apple Silicon, XNNPACK only |
| `libexecutorch_ffi-macos-arm64-xnnpack-coreml-{release,debug}.tar.gz` | Apple Silicon + CoreML |
| `libexecutorch_ffi-macos-arm64-xnnpack-mps-{release,debug}.tar.gz` | Apple Silicon + MPS (Metal) |
| `libexecutorch_ffi-macos-arm64-xnnpack-coreml-mps-{release,debug}.tar.gz` | Apple Silicon + CoreML + MPS |
| `libexecutorch_ffi-macos-x86_64-xnnpack-{release,debug}.tar.gz` | Intel Mac, XNNPACK only |
| `libexecutorch_ffi-macos-x86_64-xnnpack-coreml-{release,debug}.tar.gz` | Intel Mac + CoreML |

#### iOS Device
| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-ios-arm64-xnnpack-{release,debug}.tar.gz` | Device, XNNPACK only |
| `libexecutorch_ffi-ios-arm64-xnnpack-coreml-{release,debug}.tar.gz` | Device + CoreML |

#### iOS Simulator
| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-ios-simulator-x86_64-xnnpack-{release,debug}.tar.gz` | Simulator (Intel Mac) |
| `libexecutorch_ffi-ios-simulator-x86_64-xnnpack-coreml-{release,debug}.tar.gz` | Simulator (Intel) + CoreML |
| `libexecutorch_ffi-ios-simulator-arm64-xnnpack-{release,debug}.tar.gz` | Simulator (Apple Silicon) |
| `libexecutorch_ffi-ios-simulator-arm64-xnnpack-coreml-{release,debug}.tar.gz` | Simulator (Apple Silicon) + CoreML |

#### Linux
| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-linux-x64-xnnpack-{release,debug}.tar.gz` | x64, XNNPACK only |
| `libexecutorch_ffi-linux-arm64-xnnpack-{release,debug}.tar.gz` | ARM64, XNNPACK only |

#### Windows
| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-windows-x64-xnnpack-{release,debug}.zip` | x64, XNNPACK only |

#### Android
| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-android-arm64-v8a-xnnpack-{release,debug}.tar.gz` | ARM64, XNNPACK only |
| `libexecutorch_ffi-android-x86_64-xnnpack-{release,debug}.tar.gz` | x86_64, XNNPACK only (emulator) |

### Hash Verification

Each release binary has a corresponding `.sha256` file containing the SHA256 hash.
The build system automatically:
1. Downloads the hash file to verify integrity
2. Compares with cached versions for cache busting
3. Re-downloads if hash changes (automatic updates)

## Supported Platforms & Backends

| Platform | Architectures | Available Backends |
|----------|---------------|-------------------|
| macOS | arm64, x86_64 | XNNPACK, CoreML, MPS (arm64 only) |
| iOS Device | arm64 | XNNPACK, CoreML |
| iOS Simulator | arm64, x86_64 | XNNPACK, CoreML |
| Linux | x64, arm64 | XNNPACK |
| Windows | x64 | XNNPACK |
| Android | arm64-v8a, x86_64 | XNNPACK |

**Note**: Vulkan and QNN backends are not currently enabled in prebuilt releases.

## Building from Source

### Prerequisites

- CMake 3.18+
- Python 3.8+ with `pyyaml` package
- Platform toolchain (Xcode, NDK, Visual Studio, etc.)

### Quick Build

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --parallel
```

### Build Options

| Option | Default | Description |
|--------|---------|-------------|
| `EXECUTORCH_VERSION` | 1.0.1 | ExecuTorch source version (for source builds) |
| `EXECUTORCH_PREBUILT_VERSION` | 1.0.1.6 | Prebuilt release version (for prebuilt downloads) |
| `EXECUTORCH_BUILD_MODE` | prebuilt | `prebuilt` or `source` |
| `ET_BUILD_XNNPACK` | ON | Enable XNNPACK backend |
| `ET_BUILD_COREML` | OFF (ON for Apple) | Enable CoreML backend |
| `ET_BUILD_MPS` | OFF (ON for Apple Silicon) | Enable MPS backend |
| `ET_BUILD_VULKAN` | OFF | Enable Vulkan backend (requires glslc) |
| `ET_BUILD_QNN` | OFF | Enable QNN backend |

### Build from Source Example

```bash
cmake .. -DEXECUTORCH_BUILD_MODE=source \
         -DET_BUILD_XNNPACK=ON \
         -DET_BUILD_COREML=ON
cmake --build . --parallel
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `EXECUTORCH_CACHE_DIR` | Cache directory for faster rebuilds |
| `EXECUTORCH_DISABLE_DOWNLOAD` | Set to `1` to skip pre-built download |
| `EXECUTORCH_INSTALL_DIR` | Path to local ExecuTorch installation |

### Cache Busting Behavior

The build system implements automatic cache busting:

1. **Version-based**: Cache directory includes version number, so upgrading
   `EXECUTORCH_VERSION` automatically uses fresh downloads.

2. **Hash-based**: When a `.sha256` file is available, the system:
   - Downloads the hash file on every configure (lightweight check)
   - Compares with the cached hash
   - If different, cleans the cache and re-downloads

3. **Manual cache clear**: Delete `${EXECUTORCH_CACHE_DIR}` or the build's
   `_deps` directory to force a fresh download.

## API Reference

See `src/executorch_ffi.h` for the complete C API documentation.

### Key Functions

```c
// Load model from memory
ETStatus* et_module_load(const uint8_t* data, size_t data_size, ETModule** out);

// Load model from file
ETStatus* et_module_load_file(const char* path, ETModule** out);

// Run inference
ETStatus* et_module_forward(ETModule* module, ETTensor** inputs, int32_t input_count,
                            ETTensor*** outputs, int32_t* output_count);

// Free resources
void et_module_free(ETModule* module);
void et_tensor_free(ETTensor* tensor);
void et_status_free(ETStatus* status);
```

## License

MIT License - see LICENSE file.

## Related Projects

- [executorch_flutter](https://github.com/abdelaziz-mahdy/executorch_flutter) - Flutter plugin using this FFI
- [ExecuTorch](https://github.com/pytorch/executorch) - PyTorch on-device inference
