#!/usr/bin/env python3
"""
Analyze ExecuTorch FFI build artifact sizes and generate SVG visualization.

Downloads artifact metadata from GitHub release, parses sizes, calculates backend
impact deltas, and generates an SVG chart showing size comparisons.

Usage:
    RELEASE_TAG=v1.0.1.20 python analyze-sizes.py

Environment Variables:
    RELEASE_TAG: The release tag to analyze (required)
    GH_TOKEN: GitHub token for API access (optional, for higher rate limits)
    GITHUB_REPOSITORY: Repository in owner/repo format (default: abdelaziz-mahdy/executorch_native)
"""

import os
import sys
import json
import subprocess
from datetime import datetime, timezone
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
from pathlib import Path


@dataclass
class ArtifactInfo:
    """Parsed information about a build artifact."""
    platform: str
    arch: str
    backends: List[str]
    build_type: str
    size_bytes: int
    filename: str

    @property
    def size_mb(self) -> float:
        """Size in megabytes."""
        return self.size_bytes / (1024 * 1024)

    @property
    def backend_key(self) -> str:
        """Sorted backend combination key."""
        return "-".join(sorted(self.backends))

    @property
    def platform_arch_key(self) -> str:
        """Platform-architecture key for grouping."""
        return f"{self.platform}-{self.arch}"


@dataclass
class SizeReport:
    """Complete size analysis report."""
    release_tag: str
    generated_at: str
    platforms: Dict[str, Dict[str, Dict[str, float]]] = field(default_factory=dict)

    def to_dict(self) -> Dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "release_tag": self.release_tag,
            "generated_at": self.generated_at,
            "platforms": self.platforms
        }


def parse_artifact_name(filename: str, size_bytes: int) -> Optional[ArtifactInfo]:
    """
    Parse artifact filename into components.

    Format: libexecutorch_ffi-{platform}-{arch}-{backends}-{build_type}.{ext}

    Examples:
        libexecutorch_ffi-linux-x64-xnnpack-release.tar.gz
        libexecutorch_ffi-macos-arm64-xnnpack-coreml-release.tar.gz
        libexecutorch_ffi-ios-simulator-arm64-xnnpack-coreml-release.tar.gz
    """
    # Skip hash files and non-library files
    if filename.endswith('.sha256') or not filename.startswith('libexecutorch_ffi-'):
        return None

    # Remove prefix and extension
    name = filename.replace('libexecutorch_ffi-', '')

    # Remove extension (.tar.gz or .zip)
    if name.endswith('.tar.gz'):
        name = name[:-7]
    elif name.endswith('.zip'):
        name = name[:-4]
    else:
        return None

    parts = name.split('-')
    if len(parts) < 4:
        return None

    # Extract build type (last part)
    build_type = parts[-1]
    if build_type not in ('release', 'debug'):
        return None

    # Extract platform and architecture
    # Handle special cases like "ios-simulator-arm64" or "ios-simulator-x86_64"
    platform = parts[0]
    remaining = parts[1:-1]  # Exclude platform and build_type

    # Detect simulator/device variants for iOS
    if platform == 'ios' and remaining and remaining[0] == 'simulator':
        platform = 'ios-simulator'
        remaining = remaining[1:]

    if not remaining:
        return None

    # Architecture is the next part
    arch = remaining[0]

    # Handle arm64-v8a for Android (keep together)
    if arch == 'arm64' and len(remaining) > 1 and remaining[1] == 'v8a':
        arch = 'arm64-v8a'
        backends = remaining[2:]
    elif arch == 'armeabi' and len(remaining) > 1 and remaining[1] == 'v7a':
        arch = 'armeabi-v7a'
        backends = remaining[2:]
    else:
        backends = remaining[1:]

    # Remaining parts are backends
    if not backends:
        backends = ['xnnpack']  # Default

    return ArtifactInfo(
        platform=platform,
        arch=arch,
        backends=backends,
        build_type=build_type,
        size_bytes=size_bytes,
        filename=filename
    )


def fetch_release_assets(tag: str, repo: str) -> List[Dict]:
    """
    Fetch asset info from GitHub API using gh CLI.

    Args:
        tag: Release tag (e.g., 'v1.0.1.20')
        repo: Repository in owner/repo format

    Returns:
        List of asset dictionaries with 'name' and 'size' keys
    """
    try:
        result = subprocess.run(
            ['gh', 'api', f'repos/{repo}/releases/tags/{tag}'],
            capture_output=True,
            text=True,
            check=True
        )
        release_data = json.loads(result.stdout)
        return release_data.get('assets', [])
    except subprocess.CalledProcessError as e:
        print(f"Error fetching release {tag}: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing release data: {e}", file=sys.stderr)
        sys.exit(1)


def calculate_backend_deltas(artifacts: List[ArtifactInfo]) -> SizeReport:
    """
    Calculate size impact of each backend over xnnpack baseline.

    Groups artifacts by platform+arch, finds xnnpack-only as baseline,
    and calculates delta for each additional backend combination.
    """
    tag = os.environ.get('RELEASE_TAG', 'unknown')
    report = SizeReport(
        release_tag=tag,
        generated_at=datetime.now(timezone.utc).isoformat()
    )

    # Group by build_type -> platform+arch -> backend combination
    grouped: Dict[str, Dict[str, List[ArtifactInfo]]] = {
        'release': {},
        'debug': {}
    }

    for artifact in artifacts:
        build_group = grouped.get(artifact.build_type)
        if build_group is None:
            continue

        key = artifact.platform_arch_key
        if key not in build_group:
            build_group[key] = []
        build_group[key].append(artifact)

    # Calculate deltas for each build type
    for build_type, platform_groups in grouped.items():
        report.platforms[build_type] = {}

        for platform_arch, artifacts_list in sorted(platform_groups.items()):
            # Find baseline (xnnpack only)
            baseline = None
            for a in artifacts_list:
                if a.backend_key == 'xnnpack':
                    baseline = a
                    break

            report.platforms[build_type][platform_arch] = {}

            for artifact in sorted(artifacts_list, key=lambda x: x.size_mb):
                delta_mb = 0.0
                if baseline and artifact != baseline:
                    delta_mb = artifact.size_mb - baseline.size_mb

                report.platforms[build_type][platform_arch][artifact.backend_key] = {
                    'size_mb': round(artifact.size_mb, 2),
                    'delta_mb': round(delta_mb, 2),
                    'filename': artifact.filename
                }

    return report


def generate_svg_chart(report: SizeReport, output_path: str):
    """
    Generate SVG visualization using pygal.

    Creates a horizontal grouped bar chart showing library sizes
    by platform/architecture with backend variants.
    """
    try:
        import pygal
        from pygal.style import Style
    except ImportError:
        print("Warning: pygal not installed. Skipping SVG generation.", file=sys.stderr)
        print("Install with: pip install pygal", file=sys.stderr)
        return

    # Custom style for better readability
    custom_style = Style(
        background='#ffffff',
        plot_background='#ffffff',
        foreground='#333333',
        foreground_strong='#333333',
        foreground_subtle='#666666',
        opacity='.8',
        opacity_hover='.9',
        transition='400ms ease-in',
        colors=('#3498db', '#27ae60', '#9b59b6', '#e67e22', '#e74c3c', '#1abc9c', '#f39c12', '#2ecc71')
    )

    # Create chart
    chart = pygal.HorizontalBar(
        title=f'ExecuTorch FFI Library Sizes ({report.release_tag})',
        x_title='Size (MB)',
        style=custom_style,
        legend_at_bottom=True,
        legend_at_bottom_columns=4,
        print_values=True,
        print_values_position='center',
        value_formatter=lambda x: f'{x:.1f}' if x else '',
        height=800,
        width=1200,
        show_legend=True,
        truncate_legend=40,
        dynamic_print_values=True,
        print_zeroes=False,
        margin=20,
        spacing=10
    )

    # Collect all backend combinations across all platforms
    all_backends = set()
    for build_type_data in report.platforms.values():
        for platform_data in build_type_data.values():
            all_backends.update(platform_data.keys())

    # Sort backends: xnnpack first, then alphabetically
    sorted_backends = sorted(all_backends, key=lambda x: (0 if x == 'xnnpack' else 1, x))

    # Build labels (platform-arch combinations)
    labels = []
    for build_type in ['release', 'debug']:
        if build_type in report.platforms:
            for platform_arch in sorted(report.platforms[build_type].keys()):
                label = f"{platform_arch} ({build_type})"
                if label not in labels:
                    labels.append(label)

    chart.x_labels = labels

    # Add data series for each backend
    for backend in sorted_backends:
        values = []
        for build_type in ['release', 'debug']:
            if build_type in report.platforms:
                for platform_arch in sorted(report.platforms[build_type].keys()):
                    data = report.platforms[build_type][platform_arch].get(backend, {})
                    size = data.get('size_mb', 0)
                    delta = data.get('delta_mb', 0)

                    if size > 0:
                        # Create tooltip with delta info
                        tooltip = f"{size:.1f} MB"
                        if delta > 0:
                            tooltip += f" (+{delta:.1f} MB)"
                        values.append({'value': size, 'label': tooltip})
                    else:
                        values.append(None)

        # Format backend name for legend
        backend_display = backend.replace('-', ' + ').upper()
        chart.add(backend_display, values)

    # Render to file
    chart.render_to_file(output_path)
    print(f"Generated SVG chart: {output_path}")


def generate_simple_svg(report: SizeReport, output_path: str):
    """
    Generate a simple SVG without external dependencies.

    Fallback if pygal is not available.
    """
    # Calculate dimensions
    bar_height = 20
    bar_gap = 5
    section_gap = 30
    label_width = 200
    max_bar_width = 400
    margin = 40

    # Find max size for scaling
    max_size = 0
    total_bars = 0
    for build_type_data in report.platforms.values():
        for platform_data in build_type_data.values():
            for backend_data in platform_data.values():
                max_size = max(max_size, backend_data.get('size_mb', 0))
                total_bars += 1

    if max_size == 0:
        max_size = 1  # Avoid division by zero

    # Calculate height
    height = margin * 2 + total_bars * (bar_height + bar_gap) + len(report.platforms) * section_gap + 100
    width = margin * 2 + label_width + max_bar_width + 150

    # Color palette for backends
    colors = {
        'xnnpack': '#3498db',
        'coreml': '#27ae60',
        'mps': '#9b59b6',
        'vulkan': '#e67e22',
        'xnnpack-coreml': '#1abc9c',
        'xnnpack-mps': '#8e44ad',
        'xnnpack-vulkan': '#d35400',
        'xnnpack-coreml-mps': '#16a085',
        'coreml-mps-xnnpack': '#16a085',
    }
    default_color = '#95a5a6'

    # Build SVG
    svg_parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">',
        '<style>',
        '  .title { font: bold 16px sans-serif; fill: #333; }',
        '  .subtitle { font: 12px sans-serif; fill: #666; }',
        '  .label { font: 11px sans-serif; fill: #333; }',
        '  .value { font: 10px sans-serif; fill: #333; }',
        '  .delta { font: 10px sans-serif; fill: #27ae60; }',
        '  .section { font: bold 12px sans-serif; fill: #555; }',
        '</style>',
        f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
        f'<text x="{width/2}" y="25" text-anchor="middle" class="title">ExecuTorch FFI Library Sizes ({report.release_tag})</text>',
        f'<text x="{width/2}" y="45" text-anchor="middle" class="subtitle">Generated: {report.generated_at[:10]}</text>',
    ]

    y = 70

    for build_type in ['release', 'debug']:
        if build_type not in report.platforms:
            continue

        # Section header
        svg_parts.append(f'<text x="{margin}" y="{y}" class="section">{build_type.upper()} BUILDS</text>')
        y += 20

        for platform_arch in sorted(report.platforms[build_type].keys()):
            platform_data = report.platforms[build_type][platform_arch]

            for backend, data in sorted(platform_data.items(), key=lambda x: x[1].get('size_mb', 0)):
                size = data.get('size_mb', 0)
                delta = data.get('delta_mb', 0)

                # Label
                label = f"{platform_arch} ({backend})"
                svg_parts.append(f'<text x="{margin}" y="{y + bar_height/2 + 4}" class="label">{label}</text>')

                # Bar
                bar_width = (size / max_size) * max_bar_width if max_size > 0 else 0
                color = colors.get(backend, default_color)
                bar_x = margin + label_width
                svg_parts.append(f'<rect x="{bar_x}" y="{y}" width="{bar_width}" height="{bar_height}" fill="{color}" rx="2"/>')

                # Value
                value_x = bar_x + bar_width + 5
                svg_parts.append(f'<text x="{value_x}" y="{y + bar_height/2 + 4}" class="value">{size:.1f} MB</text>')

                # Delta (if positive)
                if delta > 0:
                    delta_x = value_x + 60
                    svg_parts.append(f'<text x="{delta_x}" y="{y + bar_height/2 + 4}" class="delta">(+{delta:.1f})</text>')

                y += bar_height + bar_gap

        y += section_gap

    # Legend
    y += 10
    svg_parts.append(f'<text x="{margin}" y="{y}" class="section">LEGEND</text>')
    y += 15
    legend_x = margin
    for backend, color in list(colors.items())[:6]:
        svg_parts.append(f'<rect x="{legend_x}" y="{y}" width="12" height="12" fill="{color}" rx="2"/>')
        svg_parts.append(f'<text x="{legend_x + 16}" y="{y + 10}" class="label">{backend}</text>')
        legend_x += 120
        if legend_x > width - 150:
            legend_x = margin
            y += 18

    svg_parts.append('</svg>')

    svg_content = '\n'.join(svg_parts)

    with open(output_path, 'w') as f:
        f.write(svg_content)

    print(f"Generated simple SVG chart: {output_path}")


def print_summary(report: SizeReport):
    """Print a human-readable summary of the size analysis."""
    print("\n" + "=" * 70)
    print(f"Size Analysis Summary - {report.release_tag}")
    print("=" * 70)

    for build_type in ['release', 'debug']:
        if build_type not in report.platforms:
            continue

        print(f"\n{build_type.upper()} BUILDS:")
        print("-" * 40)

        for platform_arch in sorted(report.platforms[build_type].keys()):
            print(f"\n  {platform_arch}:")
            platform_data = report.platforms[build_type][platform_arch]

            # Sort by size
            sorted_backends = sorted(
                platform_data.items(),
                key=lambda x: x[1].get('size_mb', 0)
            )

            for backend, data in sorted_backends:
                size = data.get('size_mb', 0)
                delta = data.get('delta_mb', 0)

                if delta > 0:
                    print(f"    {backend:30} {size:6.1f} MB  (+{delta:.1f} MB)")
                else:
                    print(f"    {backend:30} {size:6.1f} MB  (baseline)")

    print("\n" + "=" * 70)


def main():
    """Main entry point."""
    # Get configuration from environment
    tag = os.environ.get('RELEASE_TAG')
    if not tag:
        print("Error: RELEASE_TAG environment variable is required", file=sys.stderr)
        print("Usage: RELEASE_TAG=v1.0.1.20 python analyze-sizes.py", file=sys.stderr)
        sys.exit(1)

    repo = os.environ.get('GITHUB_REPOSITORY', 'abdelaziz-mahdy/executorch_native')

    print(f"Analyzing release: {tag}")
    print(f"Repository: {repo}")

    # 1. Fetch release assets
    print("\nFetching release assets...")
    assets = fetch_release_assets(tag, repo)
    print(f"Found {len(assets)} assets")

    # 2. Parse artifacts
    artifacts = []
    for asset in assets:
        name = asset.get('name', '')
        size = asset.get('size', 0)

        parsed = parse_artifact_name(name, size)
        if parsed:
            artifacts.append(parsed)

    print(f"Parsed {len(artifacts)} library artifacts")

    if not artifacts:
        print("Error: No valid artifacts found in release", file=sys.stderr)
        sys.exit(1)

    # 3. Calculate deltas and generate report
    print("\nCalculating size deltas...")
    report = calculate_backend_deltas(artifacts)

    # 4. Generate outputs
    print("\nGenerating outputs...")

    # JSON report
    with open('size-report.json', 'w') as f:
        json.dump(report.to_dict(), f, indent=2)
    print("Generated JSON report: size-report.json")

    # SVG chart (try pygal first, fall back to simple SVG)
    try:
        import pygal
        generate_svg_chart(report, 'size-report.svg')
    except ImportError:
        print("pygal not available, using simple SVG generator")
        generate_simple_svg(report, 'size-report.svg')

    # 5. Print summary
    print_summary(report)

    print("\nDone!")


if __name__ == '__main__':
    main()
