# CI/CD Workflows

This directory contains GitHub Actions workflows for building and releasing ExecuTorch native libraries.

## Workflow Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      release.yaml                                │
│                   (Orchestrator Workflow)                        │
│                                                                  │
│  Triggered by: tag push (v*) or workflow_dispatch                │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ get-version  │  │              │  │              │           │
│  │              │──►│  All builds  │──►│create-release│──► size-report
│  │              │  │  in parallel │  │              │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                           │                                      │
│         ┌─────────────────┼─────────────────┐                   │
│         ▼                 ▼                 ▼                   │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐              │
│  │build-android│   │build-apple │   │build-linux │   ...        │
│  │   .yaml    │   │   .yaml    │   │   .yaml    │              │
│  │            │   │            │   │            │              │
│  │upload_release│  │upload_release│  │upload_release│           │
│  │  = false   │   │  = false   │   │  = false   │              │
│  └────────────┘   └────────────┘   └────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

## Workflows

### `release.yaml` - Unified Release Orchestrator

**Triggers:**
- Tag push matching `v*` (e.g., `v1.1.0.4`)
- Manual `workflow_dispatch`

**What it does:**
1. Extracts version from tag
2. Calls all build workflows in parallel with `upload_release: false`
3. Waits for ALL builds to complete
4. Creates a single GitHub Release with all artifacts
5. Generates size comparison SVG charts

**Why `upload_release: false`?**
Each build workflow has its own `release` job for standalone use. When orchestrated by `release.yaml`, we skip individual releases to create ONE unified release with all platform artifacts.

### `build-android.yaml` - Android Builds

**Builds:** arm64-v8a, armeabi-v7a, x86_64, x86
**Variants:** xnnpack, xnnpack-vulkan
**Outputs:** `libexecutorch_ffi-android-{abi}-{variant}-{type}.tar.gz`

### `build-apple.yaml` - iOS/macOS Builds

**Builds:**
- iOS: arm64 (device), arm64+x86_64 (simulator)
- macOS: arm64, x86_64

**Variants:** xnnpack, xnnpack-coreml, xnnpack-mps (macOS only)
**Outputs:** `libexecutorch_ffi-{ios|macos}-{arch}-{variant}-{type}.tar.gz`

### `build-linux.yaml` - Linux Builds

**Builds:** x64, arm64
**Variants:** xnnpack, xnnpack-vulkan
**Outputs:** `libexecutorch_ffi-linux-{arch}-{variant}-{type}.tar.gz`

### `build-windows.yaml` - Windows Builds

**Builds:** x64
**Variants:** xnnpack, xnnpack-vulkan
**Outputs:** `libexecutorch_ffi-windows-x64-{variant}-{type}.zip`

## Standalone vs Orchestrated Builds

### Standalone (Individual Workflow)

When you trigger a build workflow directly (e.g., `build-linux.yaml`):
- The workflow builds artifacts
- If `upload_release: true` (default for workflow_dispatch), it creates a release

```bash
# Manual trigger for testing
gh workflow run build-linux.yaml
```

### Orchestrated (Via release.yaml)

When `release.yaml` calls build workflows:
- Build workflows run with `upload_release: false`
- Individual `release` jobs are **skipped** (intentional)
- `release.yaml`'s `create-release` job handles the unified release

```bash
# Create a release (triggers all builds)
git tag v1.1.0.5
git push origin v1.1.0.5
```

## FAQ

### Why is the "release" job skipped in build workflows?

This is intentional. When called from `release.yaml`, build workflows have `upload_release: false`, which skips their individual release jobs. The main `create-release` job in `release.yaml` handles creating one unified release.

### How long do builds take?

| Platform | Approximate Time |
|----------|------------------|
| Linux x64 | 15-20 min |
| Linux arm64 | 15-20 min |
| Android | 30-45 min |
| iOS | 30-45 min |
| macOS | 30-45 min |
| Windows | 20-30 min |

Total release time: ~45-60 minutes (builds run in parallel)

### How do I trigger a new release?

```bash
cd native/
git tag v1.1.0.X
git push origin v1.1.0.X
```

### How do I test a single platform?

```bash
# Via GitHub CLI
gh workflow run build-linux.yaml -f version=1.1.0

# Or via GitHub UI: Actions > Build Linux > Run workflow
```
