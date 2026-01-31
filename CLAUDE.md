# ExecuTorch Native FFI - AI Agent Context

## Overview

This repository contains the C/C++ FFI library for ExecuTorch, designed for use with Flutter/Dart via dart:ffi. It provides a unified C interface to ExecuTorch's C++ API, enabling cross-platform on-device ML inference.

**Repository**: `abdelaziz-mahdy/executorch_native`
**Parent Project**: [executorch_flutter](https://github.com/abdelaziz-mahdy/executorch_flutter)
**License**: MIT

## Versioning Scheme

This project uses a 4-part version: `X.Y.Z.W`

- **X.Y.Z** - ExecuTorch version (e.g., `1.0.1`)
- **W** - Build iteration for that ExecuTorch version

Example: `v1.0.1.6` = ExecuTorch 1.0.1, sixth build iteration.

## Quick Start

```bash
# Build locally (from native/ directory)
mkdir -p build && cd build
cmake .. -DEXECUTORCH_BUILD_MODE=prebuilt
cmake --build . --config Release

# Clean build
rm -rf build && mkdir build && cd build && cmake .. && cmake --build .
```

## Project Structure

```
native/
├── src/
│   ├── executorch_ffi.h         # Public C API header
│   ├── executorch_ffi.cpp       # C++ implementation
│   └── tensor_utils.h           # Internal tensor utilities
├── cmake/
│   ├── download_prebuilt.cmake  # Pre-built binary download logic
│   └── build_from_source.cmake  # Source build configuration
├── scripts/
│   ├── build-android.sh         # Android build (all ABIs)
│   ├── build-apple.sh           # iOS/macOS build
│   ├── build-linux.sh           # Linux build
│   └── build-windows.sh         # Windows build
├── CMakeLists.txt               # Main CMake configuration
└── README.md                    # Project documentation
```

## Key Files

### `src/executorch_ffi.h`

The public C API header. All functions use C linkage (`extern "C"`) for FFI compatibility. Key patterns:

- **Opaque pointers**: `ETModule*`, `ETTensor*`, `ETStatus*`
- **Error handling**: Functions return `ETStatus*` for error info
- **Memory ownership**: Clearly documented who owns/frees memory

### `CMakeLists.txt`

Controls the build process. Important options:

| Option | Default | Description |
|--------|---------|-------------|
| `EXECUTORCH_BUILD_MODE` | `prebuilt` | `prebuilt` or `source` |
| `EXECUTORCH_PREBUILT_VERSION` | current | Version tag for prebuilt downloads |
| `ET_BUILD_XNNPACK` | ON | Enable XNNPACK backend |
| `ET_BUILD_COREML` | OFF | Enable CoreML (Apple only) |
| `ET_BUILD_MPS` | OFF | Enable MPS/Metal (macOS only) |

## CI/CD Pipeline

> **Detailed Documentation:** See [`.github/workflows/README.md`](.github/workflows/README.md) for comprehensive CI/CD documentation.

### Architecture Overview

The CI/CD uses a **unified release orchestrator** pattern:

```
release.yaml (orchestrator)
    ├── build-android.yaml (upload_release: false)
    ├── build-apple.yaml   (upload_release: false)
    ├── build-linux.yaml   (upload_release: false)
    ├── build-windows.yaml (upload_release: false)
    ├── create-release     (waits for all builds, creates unified release)
    └── size-report        (generates SVG charts)
```

**Key Design:** Individual build workflows have their own `release` jobs for standalone use. When orchestrated by `release.yaml`, these are **intentionally skipped** (`upload_release: false`) so that ONE unified release is created with all platform artifacts.

### Automated Builds (GitHub Actions)

When a tag is pushed (e.g., `v1.0.1.7`), CI automatically builds:

1. **All platforms**: macOS, iOS, iOS Simulator, Linux, Windows, Android
2. **Multiple architectures**: arm64, x86_64, arm64-v8a
3. **Backend variants**: xnnpack, xnnpack-coreml, xnnpack-mps, etc.
4. **Both release and debug** configurations

Builds are uploaded to GitHub Releases as `.tar.gz` (Unix) or `.zip` (Windows).

### Release Workflow

1. Make changes to native code
2. Test locally with `cmake --build`
3. Commit and push to repository
4. Create new version tag:
   ```bash
   git tag v1.0.1.X
   git push origin v1.0.1.X
   ```
5. Wait for CI builds to complete (30-60 minutes)
6. Update `executorch_flutter` to use new version

## Making Changes

### Adding a New FFI Function

1. **Add declaration to header** (`src/executorch_ffi.h`):
   ```c
   ET_API ETStatus* et_new_function(/* params */);
   ```

2. **Implement in C++** (`src/executorch_ffi.cpp`):
   ```cpp
   ET_API ETStatus* et_new_function(/* params */) {
       ET_CHECK_ARG(param != nullptr, "param is null");
       try {
           // implementation
           ET_RETURN_OK();
       } catch (const std::exception& e) {
           ET_RETURN_ERROR(ET_ERROR_INTERNAL, e.what());
       }
   }
   ```

3. **Regenerate Dart bindings** in parent repo:
   ```bash
   cd ../  # executorch_flutter
   dart run ffigen
   ```

4. **Test** the new function from Dart

### Error Handling Pattern

```cpp
// Use macros for consistent error handling
ET_CHECK_ARG(condition, "error message");  // Validates arguments
ET_RETURN_OK();                             // Success
ET_RETURN_ERROR(ET_ERROR_CODE, "message"); // Failure
```

### Memory Management Rules

1. **Caller allocates output pointers**: `ETModule** out_module`
2. **Callee allocates content**: The function fills the pointer
3. **Caller frees**: Use `et_module_free()`, `et_tensor_free()`, etc.
4. **Status always freed**: Caller must free `ETStatus*` after checking

## Backend Support

### Currently Enabled

| Backend | Platforms | Notes |
|---------|-----------|-------|
| XNNPACK | All | Default CPU backend |
| CoreML | iOS, macOS | Apple Neural Engine |
| MPS | macOS | Metal Performance Shaders |

### Not Yet Enabled

- **Vulkan**: Requires glslc compiler in CI
- **QNN**: Requires Qualcomm SDK

## Build Artifacts Naming

```
libexecutorch_ffi-{platform}-{arch}-{backends}-{build_type}.{ext}
```

Examples:
- `libexecutorch_ffi-macos-arm64-xnnpack-release.tar.gz`
- `libexecutorch_ffi-ios-arm64-xnnpack-coreml-release.tar.gz`
- `libexecutorch_ffi-windows-x64-xnnpack-release.zip`

## Troubleshooting

### Build Failures

**CMake can't find ExecuTorch**:
```bash
# Set prebuilt version explicitly
cmake .. -DEXECUTORCH_PREBUILT_VERSION=1.0.1.6
```

**Missing backend**:
```bash
# Enable specific backends
cmake .. -DET_BUILD_COREML=ON -DET_BUILD_MPS=ON
```

### CI Issues

**Builds timing out**: macOS builds with CoreML+MPS can take 20+ minutes. Ensure CI timeout is adequate.

**Download failures**: Check that the prebuilt version exists on GitHub Releases.

## Integration with executorch_flutter

The parent Flutter plugin uses this library via:

1. **Native assets hook**: `hook/build.dart` in parent repo
2. **CMake integration**: Downloads prebuilts or builds from source
3. **FFI bindings**: Generated via `ffigen` from `executorch_ffi.h`

### Updating the Plugin

After releasing a new native version:

1. Update `_defaultPrebuiltVersion` in parent's `lib/src/build/run_build.dart`
2. Update submodule reference:
   ```bash
   cd executorch_flutter
   cd native && git pull origin main && cd ..
   git add native
   git commit -m "chore: Update native submodule to vX.X.X.X"
   ```

---

**Current Version**: See `EXECUTORCH_PREBUILT_VERSION` in CMakeLists.txt
