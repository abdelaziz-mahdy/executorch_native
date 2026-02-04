<#
.SYNOPSIS
    Build all Windows variants of ExecuTorch FFI (x64 + ARM64)

.DESCRIPTION
    Builds ALL combinations of backends for Windows:
    - x64: xnnpack, xnnpack-vulkan (if Vulkan SDK available)
    - arm64: xnnpack (not currently built - requires ARM64 runner)

.PARAMETER Version
    ExecuTorch version to build (default: 1.1.0)

.PARAMETER VulkanSdkVersion
    Vulkan SDK version to install (default: 1.4.321.0)

.EXAMPLE
    .\build-windows.ps1
    .\build-windows.ps1 -Version 1.1.0
#>

param(
    [string]$Version = "1.1.0",
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

    Write-Host "Dependencies installed successfully"
}

function Build-Variant {
    param(
        [string]$Arch,
        [string]$Backends,
        [string]$Vulkan,
        [string]$BuildType
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

    # Configure
    cmake -B $BuildDir -S $ProjectDir `
        -A $Arch `
        -T ClangCL `
        -DCMAKE_BUILD_TYPE=$BuildType `
        "-DEXECUTORCH_VERSION:STRING=$Version" `
        -DEXECUTORCH_BUILD_MODE=source `
        "-DEXECUTORCH_CACHE_DIR=$CacheDir" `
        -DET_BUILD_XNNPACK=ON `
        -DET_BUILD_VULKAN=$Vulkan `
        -DET_BUILD_COREML=OFF `
        -DET_BUILD_MPS=OFF `
        -DET_BUILD_QNN=OFF `
        -DCMAKE_INSTALL_PREFIX="$BuildDir\install"

    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

    # Build
    cmake --build $BuildDir --config $BuildType --parallel
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

    # Install
    cmake --install $BuildDir --config $BuildType
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
}

Write-Host ""
Write-Host "============================================================"
Write-Host "Build Complete!"
Write-Host "============================================================"
$ArtifactCount = (Get-ChildItem -Path "dist\*.zip" -ErrorAction SilentlyContinue).Count
Write-Host "Artifacts built: $ArtifactCount"
Get-ChildItem -Path "dist\*.zip" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.Name }
Write-Host "============================================================"
