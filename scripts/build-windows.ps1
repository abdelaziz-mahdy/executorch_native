<#
.SYNOPSIS
    Build all Windows x64 variants of ExecuTorch FFI

.DESCRIPTION
    Builds ALL combinations of backends for Windows x64:
    - xnnpack
    - xnnpack-vulkan

.PARAMETER Version
    ExecuTorch version to build (default: 1.0.1)

.PARAMETER VulkanSdkVersion
    Vulkan SDK version to install (default: 1.3.290.0)

.EXAMPLE
    .\build-windows.ps1
    .\build-windows.ps1 -Version 1.0.1
#>

param(
    [string]$Version = "1.0.1",
    [string]$VulkanSdkVersion = "1.3.290.0"
)

$ErrorActionPreference = "Stop"

$Arch = "x64"
$Platform = "windows"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# All variants to build: backends:vulkan
$Variants = @(
    @{ Backends = "xnnpack"; Vulkan = "OFF" },
    @{ Backends = "xnnpack-vulkan"; Vulkan = "ON" }
)

Write-Host "============================================================"
Write-Host "ExecuTorch Windows Build Script"
Write-Host "============================================================"
Write-Host "  Version: $Version"
Write-Host "  Platform: $Platform"
Write-Host "  Architecture: $Arch"
Write-Host "  Variants: $($Variants.Count)"
Write-Host "============================================================"

function Install-Dependencies {
    Write-Host ""
    Write-Host "=== Installing dependencies ==="

    # Install Python dependencies
    pip install pyyaml torch --extra-index-url https://download.pytorch.org/whl/cpu

    # Install Vulkan SDK
    Write-Host "Installing Vulkan SDK $VulkanSdkVersion..."
    $VulkanUrl = "https://sdk.lunarg.com/sdk/download/$VulkanSdkVersion/windows/VulkanSDK-$VulkanSdkVersion-Installer.exe"
    $InstallerPath = "$env:TEMP\VulkanSDK-Installer.exe"

    Write-Host "Downloading Vulkan SDK from $VulkanUrl"
    Invoke-WebRequest -Uri $VulkanUrl -OutFile $InstallerPath

    Write-Host "Installing Vulkan SDK..."
    Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait

    $VulkanPath = "C:\VulkanSDK\$VulkanSdkVersion"
    $env:VULKAN_SDK = $VulkanPath
    $env:PATH = "$VulkanPath\Bin;$env:PATH"

    Write-Host "Dependencies installed successfully"
}

function Build-Variant {
    param(
        [string]$Backends,
        [string]$Vulkan,
        [string]$BuildType
    )

    $BuildTypeLower = $BuildType.ToLower()
    $BuildDir = "$ProjectDir\build-$Platform-$Arch-$Backends-$BuildTypeLower"
    $ArtifactName = "libexecutorch_ffi-$Platform-$Arch-$Backends-$BuildTypeLower.zip"

    Write-Host ""
    Write-Host "=== Building $Platform-$Arch-$Backends-$BuildTypeLower ==="
    Write-Host "  Build directory: $BuildDir"

    # Configure
    cmake -B $BuildDir -S $ProjectDir `
        -A $Arch `
        -T ClangCL `
        -DCMAKE_BUILD_TYPE=$BuildType `
        "-DEXECUTORCH_VERSION:STRING=$Version" `
        -DEXECUTORCH_BUILD_MODE=source `
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

# Build all variants
foreach ($Variant in $Variants) {
    Build-Variant -Backends $Variant.Backends -Vulkan $Variant.Vulkan -BuildType "Release"
    Build-Variant -Backends $Variant.Backends -Vulkan $Variant.Vulkan -BuildType "Debug"
}

Write-Host ""
Write-Host "============================================================"
Write-Host "Build Complete!"
Write-Host "============================================================"
$ArtifactCount = (Get-ChildItem -Path "dist\*.zip" -ErrorAction SilentlyContinue).Count
Write-Host "Artifacts built: $ArtifactCount"
Get-ChildItem -Path "dist\*.zip" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.Name }
Write-Host "============================================================"
