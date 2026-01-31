# ExecuTorch Native FFI

C/C++ FFI wrapper for ExecuTorch, designed for use with Flutter/Dart via dart:ffi.

---

## Table of Contents

- [Versioning](#versioning)
- [Overview](#overview)
- [Pre-built Binaries](#pre-built-binaries)
- [Supported Platforms](#supported-platforms--backends)
- [Building from Source](#building-from-source)
- [API Reference](#api-reference)
- [CI/CD](#cicd)
- [Related Projects](#related-projects)

---

## Versioning

This project uses a 4-part version scheme: `X.Y.Z.W`

| Part | Meaning | Example |
|------|---------|---------|
| X.Y.Z | ExecuTorch version | `1.0.1` |
| W | Build iteration | `6` |

**Example**: `v1.0.1.6` = ExecuTorch 1.0.1, sixth build iteration.

When ExecuTorch releases a new version, X.Y.Z updates and W resets to 1.

---

## Overview

This repository provides:

- **C FFI interface** (`src/executorch_ffi.h`) for cross-platform bindings
- **Pre-built binaries** for all major platforms (via GitHub Releases)
- **Build-from-source** option for custom configurations

---

## Pre-built Binaries

### Naming Convention

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

### Available Artifacts

<details>
<summary><b>macOS</b></summary>

| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-macos-arm64-xnnpack-*.tar.gz` | Apple Silicon, XNNPACK |
| `libexecutorch_ffi-macos-arm64-xnnpack-coreml-*.tar.gz` | Apple Silicon + CoreML |
| `libexecutorch_ffi-macos-arm64-xnnpack-mps-*.tar.gz` | Apple Silicon + MPS |
| `libexecutorch_ffi-macos-arm64-xnnpack-coreml-mps-*.tar.gz` | Apple Silicon + CoreML + MPS |
| `libexecutorch_ffi-macos-x86_64-xnnpack-*.tar.gz` | Intel Mac |
| `libexecutorch_ffi-macos-x86_64-xnnpack-coreml-*.tar.gz` | Intel Mac + CoreML |
</details>

<details>
<summary><b>iOS Device</b></summary>

| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-ios-arm64-xnnpack-*.tar.gz` | Device, XNNPACK |
| `libexecutorch_ffi-ios-arm64-xnnpack-coreml-*.tar.gz` | Device + CoreML |
</details>

<details>
<summary><b>iOS Simulator</b></summary>

| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-ios-simulator-arm64-xnnpack-*.tar.gz` | Simulator (Apple Silicon) |
| `libexecutorch_ffi-ios-simulator-arm64-xnnpack-coreml-*.tar.gz` | Simulator (Apple Silicon) + CoreML |
| `libexecutorch_ffi-ios-simulator-x86_64-xnnpack-*.tar.gz` | Simulator (Intel) |
| `libexecutorch_ffi-ios-simulator-x86_64-xnnpack-coreml-*.tar.gz` | Simulator (Intel) + CoreML |
</details>

<details>
<summary><b>Linux</b></summary>

| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-linux-x64-xnnpack-*.tar.gz` | x64, XNNPACK |
| `libexecutorch_ffi-linux-arm64-xnnpack-*.tar.gz` | ARM64, XNNPACK |
</details>

<details>
<summary><b>Windows</b></summary>

| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-windows-x64-xnnpack-*.zip` | x64, XNNPACK |
</details>

<details>
<summary><b>Android</b></summary>

| Artifact | Description |
|----------|-------------|
| `libexecutorch_ffi-android-arm64-v8a-xnnpack-*.tar.gz` | ARM64 |
| `libexecutorch_ffi-android-x86_64-xnnpack-*.tar.gz` | x86_64 (emulator) |
</details>

### Hash Verification

Each release includes `.sha256` files for integrity verification. The build system automatically:
1. Downloads hash file
2. Compares with cached version
3. Re-downloads if hash changes

---

## Supported Platforms & Backends

| Platform | Architectures | Backends |
|----------|---------------|----------|
| macOS | arm64, x86_64 | XNNPACK, CoreML, MPS (arm64 only) |
| iOS Device | arm64 | XNNPACK, CoreML |
| iOS Simulator | arm64, x86_64 | XNNPACK, CoreML |
| Linux | x64, arm64 | XNNPACK |
| Windows | x64 | XNNPACK |
| Android | arm64-v8a, x86_64 | XNNPACK |

> **Note**: Vulkan and QNN backends are not currently enabled in prebuilt releases.

---

## Building from Source

### Prerequisites

- CMake 3.18+
- Python 3.8+ with `pyyaml`
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
| `EXECUTORCH_VERSION` | 1.0.1 | ExecuTorch source version |
| `EXECUTORCH_PREBUILT_VERSION` | 1.0.1.6 | Prebuilt release version |
| `EXECUTORCH_BUILD_MODE` | prebuilt | `prebuilt` or `source` |
| `ET_BUILD_XNNPACK` | ON | Enable XNNPACK |
| `ET_BUILD_COREML` | OFF (ON for Apple) | Enable CoreML |
| `ET_BUILD_MPS` | OFF (ON for Apple Silicon) | Enable MPS |
| `ET_BUILD_VULKAN` | OFF | Enable Vulkan (requires glslc) |

### Example: Build from Source with Custom Backends

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

---

## API Reference

See `src/executorch_ffi.h` for complete documentation.

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

---

## CI/CD

See [`.github/workflows/README.md`](.github/workflows/README.md) for detailed CI/CD documentation.

### Release Workflow

1. Push a tag: `git tag v1.0.1.7 && git push origin v1.0.1.7`
2. CI builds all platforms in parallel (~45-60 min)
3. Unified release created with all artifacts
4. Size report SVGs generated

---

## Related Projects

- [executorch_flutter](https://github.com/abdelaziz-mahdy/executorch_flutter) - Flutter plugin using this FFI
- [ExecuTorch](https://github.com/pytorch/executorch) - PyTorch on-device inference

---

## License

MIT License - see LICENSE file.
