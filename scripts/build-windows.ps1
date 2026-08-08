<#
.SYNOPSIS
    Build all Windows variants of ExecuTorch FFI (x64 + ARM64)

.DESCRIPTION
    Builds ALL combinations of backends for Windows:
    - x64: xnnpack, xnnpack-vulkan (if Vulkan SDK available)
    - arm64: xnnpack (not currently built - requires ARM64 runner)

.PARAMETER Version
    ExecuTorch version to build (default: 1.4.0)

.PARAMETER VulkanSdkVersion
    Vulkan SDK version to install (default: 1.4.321.0)

.EXAMPLE
    .\build-windows.ps1
    .\build-windows.ps1 -Version 1.4.0
#>

param(
    [string]$Version = "1.4.0",
    [string]$VulkanSdkVersion = "1.4.321.0"
)

$ErrorActionPreference = "Stop"

$Platform = "windows"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$CacheDir = "$ProjectDir\.cache"

# Architectures to build
# NOTE: ARM64 cross-compilation not supported - ExecuTorch build tools (flatc) need to run on host
# Would require ARM64 Windows runner which GitHub doesn't provide
$Architectures = @("x64")

# Check for Vulkan SDK / glslc availability
function Test-VulkanAvailable {
    $GlslcPath = Get-Command "glslc" -ErrorAction SilentlyContinue
    if ($GlslcPath) {
        return $true
    } elseif ($env:VULKAN_SDK -and (Test-Path "$env:VULKAN_SDK\Bin\glslc.exe")) {
        $env:PATH = "$env:VULKAN_SDK\Bin;$env:PATH"
        return $true
    }
    return $false
}

# All variants to build - if Vulkan variant is listed and SDK is missing, build will fail
$Variants = @(
    @{ Backends = "xnnpack"; Vulkan = "OFF" }
    @{ Backends = "xnnpack-vulkan"; Vulkan = "ON" }
)

# LLM (text generation) variants - separate from the tensor-only variants above
# so vision builds don't carry the runner/tokenizers. The variant name MUST match
# the suffix EXECUTORCH_VARIANT computes (xnnpack + llm), so the package's prebuilt
# download resolves.
#  - xnnpack-llm : CPU LLM (pure XNNPACK)
$LlmVariants = @(
    @{ Backends = "xnnpack-llm"; Vulkan = "OFF"; Llm = "ON" }
)

Write-Host "============================================================"
Write-Host "ExecuTorch Windows Build Script"
Write-Host "============================================================"
Write-Host "  Version: $Version"
Write-Host "  Platform: $Platform"
Write-Host "  Architectures: $($Architectures -join ', ')"
Write-Host "  Variants: $($Variants.Count)"
Write-Host "============================================================"

function Install-Dependencies {
    Write-Host ""
    Write-Host "=== Installing dependencies ==="

    # Install Python dependencies
    pip install pyyaml torch --extra-index-url https://download.pytorch.org/whl/cpu

    # Ninja (single-config generator). pip drops ninja.exe on PATH (Python Scripts
    # dir). We moved off the Visual Studio/MSBuild generator because it ignores
    # CMAKE_*_COMPILER_LAUNCHER (so ccache never engaged) and rebuilt all of
    # ExecuTorch per variant; Ninja honors the launcher AND lets variants share one
    # ExecuTorch sub-build (EXECUTORCH_SHARED_BINARY_DIR), and it doesn't use
    # MSBuild's FileTracker so the abseil MAX_PATH/.tlog overflow goes away too.
    pip install ninja

    Write-Host "Dependencies installed successfully"
}

function Build-Variant {
    param(
        [string]$Arch,
        [string]$Backends,
        [string]$Vulkan,
        [string]$BuildType,
        [string]$Llm = "OFF"
    )

    $BuildTypeLower = $BuildType.ToLower()
    # Use lowercase arch in artifact name for consistency
    $ArchLower = $Arch.ToLower()
    $BuildDir = "$ProjectDir\build-$Platform-$ArchLower-$Backends-$BuildTypeLower"
    $ArtifactName = "libexecutorch_ffi-$Platform-$ArchLower-$Backends-$BuildTypeLower.zip"

    Write-Host ""
    Write-Host "=== Building $Platform-$ArchLower-$Backends-$BuildTypeLower ==="
    Write-Host "  Build directory: $BuildDir"

    # Check Vulkan requirement
    if ($Vulkan -eq "ON") {
        if (-not (Test-VulkanAvailable)) {
            Write-Error "ERROR: Vulkan variant requested but glslc not found"
            Write-Error "Please install the Vulkan SDK (https://vulkan.lunarg.com/sdk/home)"
            exit 1
        }
        Write-Host "  Vulkan: enabled (glslc found)"
    }

    # COMPILE-ONCE / LINK-MANY (executorch_native#6): x64 variants of the same
    # build_type share ONE ExecuTorch sub-build, so ExecuTorch is compiled once per
    # build_type (Release/Debug) instead of once per variant. Works because Ninja is
    # a single-config generator that does proper incremental reuse (+ honors ccache).
    $SharedEtDir = "$ProjectDir\.et-shared\windows-$ArchLower-$BuildTypeLower"

    # Configure with Ninja + clang-cl ($ClangCl discovered in Main). Ninja honors
    # CMAKE_*_COMPILER_LAUNCHER (ccache) — the VS/MSBuild generator ignored it — and
    # supports the shared sub-build dir; it also avoids MSBuild FileTracker, so the
    # abseil MAX_PATH/.tlog (FTK1011) overflow no longer occurs.
    # NB: every -D flag carrying a $variable MUST be double-quoted. PowerShell does
    # NOT expand the variable in the bareword form `-Dfoo=$var` (it reaches CMake as
    # the literal "$var"). The VS generator tolerated that (it ignores
    # CMAKE_BUILD_TYPE, and a literal "$Vulkan"/"$Llm" reads as truthy so every
    # variant silently got Vulkan+LLM), but Ninja writes the build type into rule
    # names and dies on the `$`. Quoting forces expansion AND makes the per-variant
    # backend selection correct.
    cmake -B $BuildDir -S $ProjectDir -G Ninja `
        "-DCMAKE_BUILD_TYPE=$BuildType" `
        "-DCMAKE_C_COMPILER=$ClangCl" `
        "-DCMAKE_CXX_COMPILER=$ClangCl" `
        "-DEXECUTORCH_VERSION:STRING=$Version" `
        -DEXECUTORCH_BUILD_MODE=source `
        "-DEXECUTORCH_CACHE_DIR=$CacheDir" `
        "-DEXECUTORCH_SHARED_BINARY_DIR=$SharedEtDir" `
        -DET_BUILD_XNNPACK=ON `
        "-DET_BUILD_VULKAN=$Vulkan" `
        "-DET_BUILD_LLM=$Llm" `
        -DET_BUILD_COREML=OFF `
        -DET_BUILD_MPS=OFF `
        -DET_BUILD_QNN=OFF `
        "-DCMAKE_INSTALL_PREFIX=$BuildDir\install"

    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

    # Build (Ninja is single-config — build type came from CMAKE_BUILD_TYPE above)
    cmake --build $BuildDir --parallel
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

    # Install
    cmake --install $BuildDir
    if ($LASTEXITCODE -ne 0) { throw "CMake install failed" }

    # Package
    Write-Host "Packaging $ArtifactName..."
    Compress-Archive -Path "$BuildDir\install\*" -DestinationPath "$ProjectDir\dist\$ArtifactName" -Force

    Write-Host "Built: dist\$ArtifactName"
}

# Main
Set-Location $ProjectDir

# Install dependencies
Install-Dependencies

# Create dist directory
New-Item -ItemType Directory -Force -Path dist | Out-Null

# Locate clang-cl. Ninja needs an explicit compiler (the VS generator selected it
# implicitly via -T ClangCL). clang-cl ships with the VS "C++ Clang tools for
# Windows" component; find the install via vswhere. The MSVC dev environment
# (set up in the workflow) supplies link.exe + the Windows SDK that clang-cl uses.
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VsPath = & $VsWhere -latest -property installationPath
$ClangCl = Join-Path $VsPath "VC\Tools\Llvm\x64\bin\clang-cl.exe"
if (-not (Test-Path $ClangCl)) {
    throw "clang-cl not found at $ClangCl (VS 'C++ Clang tools for Windows' component required)"
}
Write-Host "Using clang-cl: $ClangCl"

# Build all architecture and variant combinations
foreach ($Arch in $Architectures) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Building $Arch variants"
    Write-Host "============================================================"

    foreach ($Variant in $Variants) {
        Build-Variant -Arch $Arch -Backends $Variant.Backends -Vulkan $Variant.Vulkan -BuildType "Release"
        Build-Variant -Arch $Arch -Backends $Variant.Backends -Vulkan $Variant.Vulkan -BuildType "Debug"
    }

    # Build LLM variants (pure CPU/XNNPACK)
    foreach ($Variant in $LlmVariants) {
        Build-Variant -Arch $Arch -Backends $Variant.Backends -Vulkan $Variant.Vulkan -BuildType "Release" -Llm $Variant.Llm
        Build-Variant -Arch $Arch -Backends $Variant.Backends -Vulkan $Variant.Vulkan -BuildType "Debug" -Llm $Variant.Llm
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "Build Complete!"
Write-Host "============================================================"
$ArtifactCount = (Get-ChildItem -Path "dist\*.zip" -ErrorAction SilentlyContinue).Count
Write-Host "Artifacts built: $ArtifactCount"
Get-ChildItem -Path "dist\*.zip" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.Name }
Write-Host "============================================================"
