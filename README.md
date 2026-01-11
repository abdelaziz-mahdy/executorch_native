# ExecuTorch Native FFI

C/C++ FFI wrapper for ExecuTorch, designed for use with Flutter/Dart via dart:ffi.

## Overview

This repository provides:
- **C FFI interface** (`src/executorch_ffi.h`) for cross-platform bindings
- **Pre-built binaries** for all major platforms (via GitHub Releases)
- **Build-from-source** option for custom configurations

## Supported Platforms

| Platform | Architectures | Backends |
|----------|---------------|----------|
| Android | arm64-v8a, x86_64 | XNNPACK, QNN |
| iOS | arm64 | XNNPACK, CoreML |
| macOS | arm64, x64 | XNNPACK, CoreML, MPS |
| Linux | x64, arm64 | XNNPACK, Vulkan |
| Windows | x64, arm64 | XNNPACK, Vulkan |

## Pre-built Binaries

Pre-built binaries are available as GitHub Releases:

```
libexecutorch_ffi-{platform}-{arch}-{backends}.tar.gz
```

Examples:
- `libexecutorch_ffi-macos-arm64-xnnpack-coreml-mps.tar.gz`
- `libexecutorch_ffi-windows-x64-xnnpack.tar.gz`
- `libexecutorch_ffi-linux-x64-vulkan.tar.gz`

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
| `EXECUTORCH_VERSION` | 1.0.1 | ExecuTorch version |
| `EXECUTORCH_BUILD_MODE` | prebuilt | `prebuilt` or `source` |
| `ET_BUILD_XNNPACK` | ON | Enable XNNPACK backend |
| `ET_BUILD_COREML` | OFF (ON for Apple) | Enable CoreML backend |
| `ET_BUILD_MPS` | OFF (ON for Apple Silicon) | Enable MPS backend |
| `ET_BUILD_VULKAN` | OFF | Enable Vulkan backend |
| `ET_BUILD_QNN` | OFF | Enable QNN backend |

### Build from Source

```bash
cmake .. -DEXECUTORCH_BUILD_MODE=source \
         -DET_BUILD_XNNPACK=ON \
         -DET_BUILD_VULKAN=ON
cmake --build . --parallel
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `EXECUTORCH_CACHE_DIR` | Cache directory for faster rebuilds |
| `EXECUTORCH_DISABLE_DOWNLOAD` | Set to `1` to skip pre-built download |
| `EXECUTORCH_INSTALL_DIR` | Path to local ExecuTorch installation |

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

- [executorch_flutter](https://github.com/user/executorch_flutter) - Flutter plugin using this FFI
- [ExecuTorch](https://github.com/pytorch/executorch) - PyTorch on-device inference
