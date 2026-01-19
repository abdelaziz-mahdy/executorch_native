#!/usr/bin/env python3
"""
Analyze ExecuTorch FFI build artifact sizes and generate SVG visualizations.

Generates separate compact SVGs for release and debug builds.

Usage:
    RELEASE_TAG=v1.0.1.20 python analyze-sizes.py
"""

import os
import sys
import json
import subprocess
from datetime import datetime, timezone
from dataclasses import dataclass, field
from typing import Dict, List, Optional


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
        return self.size_bytes / (1024 * 1024)

    @property
    def backend_key(self) -> str:
        return "-".join(sorted(self.backends))

    @property
    def platform_arch_key(self) -> str:
        return f"{self.platform}-{self.arch}"


def parse_artifact_name(filename: str, size_bytes: int) -> Optional[ArtifactInfo]:
    """Parse artifact filename into components."""
    if filename.endswith('.sha256') or not filename.startswith('libexecutorch_ffi-'):
        return None

    name = filename.replace('libexecutorch_ffi-', '')
    if name.endswith('.tar.gz'):
        name = name[:-7]
    elif name.endswith('.zip'):
        name = name[:-4]
    else:
        return None

    parts = name.split('-')
    if len(parts) < 4:
        return None

    build_type = parts[-1]
    if build_type not in ('release', 'debug'):
        return None

    platform = parts[0]
    remaining = parts[1:-1]

    if platform == 'ios' and remaining and remaining[0] == 'simulator':
        platform = 'ios-simulator'
        remaining = remaining[1:]

    if not remaining:
        return None

    arch = remaining[0]
    if arch == 'arm64' and len(remaining) > 1 and remaining[1] == 'v8a':
        arch = 'arm64-v8a'
        backends = remaining[2:]
    elif arch == 'armeabi' and len(remaining) > 1 and remaining[1] == 'v7a':
        arch = 'armeabi-v7a'
        backends = remaining[2:]
    else:
        backends = remaining[1:]

    if not backends:
        backends = ['xnnpack']

    return ArtifactInfo(
        platform=platform, arch=arch, backends=backends,
        build_type=build_type, size_bytes=size_bytes, filename=filename
    )


def fetch_release_assets(tag: str, repo: str) -> List[Dict]:
    """Fetch asset info from GitHub API."""
    try:
        result = subprocess.run(
            ['gh', 'api', f'repos/{repo}/releases/tags/{tag}'],
            capture_output=True, text=True, check=True
        )
        return json.loads(result.stdout).get('assets', [])
    except subprocess.CalledProcessError as e:
        print(f"Error fetching release {tag}: {e.stderr}", file=sys.stderr)
        sys.exit(1)


def generate_compact_svg(artifacts: List[ArtifactInfo], build_type: str, tag: str, output_path: str):
    """Generate a compact SVG for one build type."""
    # Filter artifacts for this build type
    filtered = [a for a in artifacts if a.build_type == build_type]
    if not filtered:
        print(f"No {build_type} artifacts found, skipping SVG")
        return

    # Group by platform-arch
    grouped: Dict[str, List[ArtifactInfo]] = {}
    for a in filtered:
        key = a.platform_arch_key
        if key not in grouped:
            grouped[key] = []
        grouped[key].append(a)

    # Sort platforms in logical order
    platform_order = ['android', 'ios', 'ios-simulator', 'macos', 'linux', 'windows']
    def sort_key(k):
        platform = k.split('-')[0]
        try:
            return (platform_order.index(platform), k)
        except ValueError:
            return (99, k)

    sorted_platforms = sorted(grouped.keys(), key=sort_key)

    # Colors for backends
    colors = {
        'xnnpack': '#3498db',
        'coreml-xnnpack': '#27ae60',
        'mps-xnnpack': '#9b59b6',
        'vulkan-xnnpack': '#e67e22',
        'coreml-mps-xnnpack': '#1abc9c',
        'coreml-vulkan-xnnpack': '#e74c3c',
        'mps-vulkan-xnnpack': '#f39c12',
        'coreml-mps-vulkan-xnnpack': '#2c3e50',
    }

    # Calculate dimensions
    row_height = 18
    row_gap = 3
    platform_gap = 8
    margin_left = 15
    margin_right = 15
    margin_top = 35
    margin_bottom = 10
    label_width = 140
    bar_max_width = 280
    value_width = 80

    # Count total rows
    total_rows = sum(len(v) for v in grouped.values())
    total_platform_gaps = len(grouped) - 1

    height = margin_top + margin_bottom + total_rows * (row_height + row_gap) + total_platform_gaps * platform_gap
    width = margin_left + label_width + bar_max_width + value_width + margin_right

    # Find max size for scaling
    max_size = max(a.size_mb for a in filtered) if filtered else 1

    # Build SVG
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">',
        '<style>',
        '  .title { font: bold 13px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #333; }',
        '  .label { font: 10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #555; }',
        '  .value { font: 10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #333; }',
        '  .delta { font: 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #27ae60; }',
        '  .bar { rx: 2; }',
        '</style>',
        f'<rect width="{width}" height="{height}" fill="#fafafa"/>',
        f'<text x="{width/2}" y="22" text-anchor="middle" class="title">{build_type.upper()} Build Sizes ({tag})</text>',
    ]

    y = margin_top

    for platform_arch in sorted_platforms:
        artifacts_list = grouped[platform_arch]

        # Find baseline (xnnpack only)
        baseline_size = 0
        for a in artifacts_list:
            if a.backend_key == 'xnnpack':
                baseline_size = a.size_mb
                break

        # Sort by size
        for artifact in sorted(artifacts_list, key=lambda x: x.size_mb):
            backend = artifact.backend_key
            size = artifact.size_mb
            delta = size - baseline_size if baseline_size and backend != 'xnnpack' else 0

            # Label (platform-arch + backend short name)
            backend_short = backend.replace('xnnpack', 'X').replace('coreml', 'C').replace('mps', 'M').replace('vulkan', 'V')
            if backend_short == 'X':
                backend_short = 'xnnpack'
            label = f"{platform_arch}"
            if backend != 'xnnpack':
                label += f" +{backend_short.replace('-X', '').replace('X-', '')}"

            svg.append(f'<text x="{margin_left}" y="{y + row_height/2 + 3}" class="label">{label}</text>')

            # Bar
            bar_width = (size / max_size) * bar_max_width if max_size > 0 else 0
            color = colors.get(backend, '#95a5a6')
            bar_x = margin_left + label_width
            svg.append(f'<rect x="{bar_x}" y="{y + 2}" width="{bar_width}" height="{row_height - 4}" fill="{color}" class="bar"/>')

            # Value
            value_x = bar_x + bar_max_width + 5
            svg.append(f'<text x="{value_x}" y="{y + row_height/2 + 3}" class="value">{size:.1f} MB</text>')

            # Delta
            if delta > 0:
                delta_x = value_x + 45
                svg.append(f'<text x="{delta_x}" y="{y + row_height/2 + 3}" class="delta">+{delta:.1f}</text>')

            y += row_height + row_gap

        y += platform_gap

    svg.append('</svg>')

    with open(output_path, 'w') as f:
        f.write('\n'.join(svg))

    print(f"Generated: {output_path}")


def main():
    tag = os.environ.get('RELEASE_TAG')
    if not tag:
        print("Error: RELEASE_TAG required", file=sys.stderr)
        sys.exit(1)

    repo = os.environ.get('GITHUB_REPOSITORY', 'abdelaziz-mahdy/executorch_native')

    print(f"Analyzing: {tag} from {repo}")

    # Fetch and parse
    assets = fetch_release_assets(tag, repo)
    artifacts = [parse_artifact_name(a['name'], a['size']) for a in assets]
    artifacts = [a for a in artifacts if a]

    print(f"Found {len(artifacts)} artifacts")

    if not artifacts:
        print("No artifacts found", file=sys.stderr)
        sys.exit(1)

    # Generate separate SVGs
    generate_compact_svg(artifacts, 'release', tag, 'size-report-release.svg')
    generate_compact_svg(artifacts, 'debug', tag, 'size-report-debug.svg')

    # Generate JSON report (includes both)
    report = {
        'release_tag': tag,
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'artifacts': {}
    }

    for a in artifacts:
        key = f"{a.build_type}/{a.platform_arch_key}/{a.backend_key}"
        report['artifacts'][key] = {
            'size_mb': round(a.size_mb, 2),
            'filename': a.filename
        }

    with open('size-report.json', 'w') as f:
        json.dump(report, f, indent=2)

    print("Generated: size-report.json")
    print("Done!")


if __name__ == '__main__':
    main()
