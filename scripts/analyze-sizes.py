#!/usr/bin/env python3
"""
Analyze ExecuTorch FFI build artifact sizes and generate SVG visualizations.

Generates separate SVGs for release and debug builds with platform cards.
"""

import os
import sys
import json
import subprocess
from datetime import datetime, timezone
from dataclasses import dataclass
from typing import Dict, List, Optional


@dataclass
class ArtifactInfo:
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
    def backend_count(self) -> int:
        return len(self.backends)


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


def generate_svg(artifacts: List[ArtifactInfo], build_type: str, tag: str, output_path: str):
    """Generate SVG for one build type."""
    filtered = [a for a in artifacts if a.build_type == build_type]
    if not filtered:
        print(f"No {build_type} artifacts found, skipping")
        return

    # Platform display order and names
    platform_order = ['android', 'ios', 'ios-simulator', 'macos', 'linux', 'windows']
    platform_names = {
        'android': 'Android',
        'ios': 'iOS',
        'ios-simulator': 'iOS Simulator',
        'macos': 'macOS',
        'linux': 'Linux',
        'windows': 'Windows'
    }

    # Colors
    colors = {
        'card_bg': '#ffffff',
        'card_border': '#e1e4e8',
        'header_bg': '#f6f8fa',
        'xnnpack': '#3498db',
        'vulkan': '#e67e22',
        'coreml': '#27ae60',
        'mps': '#9b59b6',
    }

    # Group by platform, then by arch
    platforms: Dict[str, Dict[str, List[ArtifactInfo]]] = {}
    for a in filtered:
        if a.platform not in platforms:
            platforms[a.platform] = {}
        if a.arch not in platforms[a.platform]:
            platforms[a.platform][a.arch] = []
        platforms[a.platform][a.arch].append(a)

    # Find max size for scaling (only from artifacts we'll display)
    display_artifacts = []
    for platform_data in platforms.values():
        for arts in platform_data.values():
            baseline = next((a for a in arts if a.backend_key == 'xnnpack'), None)
            baseline_size = baseline.size_mb if baseline else 0
            for a in arts:
                # Only show: baseline OR single-backend additions with meaningful delta
                is_baseline = a.backend_key == 'xnnpack'
                is_single_addition = a.backend_count == 2 and 'xnnpack' in a.backends
                delta = a.size_mb - baseline_size
                if is_baseline or (is_single_addition and delta > 0.5):
                    display_artifacts.append(a)

    max_size = max(a.size_mb for a in display_artifacts) if display_artifacts else 1

    # Card dimensions
    card_width = 200
    card_padding = 10
    card_gap = 12
    row_height = 20
    bar_height = 14
    bar_max_width = 90
    cols = 3

    margin = 16
    title_height = 30
    note_height = 24

    sorted_platforms = sorted(platforms.keys(),
        key=lambda p: platform_order.index(p) if p in platform_order else 99)

    # Calculate card heights
    card_heights = {}
    for platform in sorted_platforms:
        archs = platforms[platform]
        rows = 0
        for arch, arts in archs.items():
            rows += 1  # arch header
            baseline = next((a for a in arts if a.backend_key == 'xnnpack'), None)
            baseline_size = baseline.size_mb if baseline else 0
            for a in arts:
                is_baseline = a.backend_key == 'xnnpack'
                is_single_addition = a.backend_count == 2 and 'xnnpack' in a.backends
                delta = a.size_mb - baseline_size
                if is_baseline or (is_single_addition and delta > 0.5):
                    rows += 1
        card_heights[platform] = 28 + rows * row_height + card_padding

    # Calculate layout
    current_x = 0
    max_row_height = 0
    total_rows_height = 0

    for i, platform in enumerate(sorted_platforms):
        h = card_heights[platform]
        if current_x + card_width > cols * (card_width + card_gap):
            current_x = 0
            total_rows_height += max_row_height + card_gap
            max_row_height = 0
        max_row_height = max(max_row_height, h)
        current_x += card_width + card_gap

    total_rows_height += max_row_height

    total_width = margin * 2 + cols * card_width + (cols - 1) * card_gap
    total_height = title_height + total_rows_height + note_height + margin + 20

    # Build SVG
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total_width} {total_height}">',
        '<style>',
        '  .title { font: bold 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .platform-name { font: bold 10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .arch-name { font: 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #586069; }',
        '  .size-value { font: 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .delta { font: 8px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #22863a; }',
        '  .bar-label { font: 7px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: white; }',
        '  .legend { font: 8px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #586069; }',
        '  .note { font: italic 8px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #6a737d; }',
        '</style>',
        f'<rect width="{total_width}" height="{total_height}" fill="#f6f8fa"/>',
        f'<text x="{total_width/2}" y="20" text-anchor="middle" class="title">{build_type.capitalize()} Build Sizes ({tag})</text>',
    ]

    # Draw cards
    current_x = margin
    current_y = title_height
    max_row_height = 0

    for platform in sorted_platforms:
        h = card_heights[platform]
        archs = platforms[platform]

        if current_x + card_width > margin + cols * (card_width + card_gap):
            current_x = margin
            current_y += max_row_height + card_gap
            max_row_height = 0

        x, y = current_x, current_y
        max_row_height = max(max_row_height, h)
        current_x += card_width + card_gap

        # Card background
        svg.append(f'<rect x="{x}" y="{y}" width="{card_width}" height="{h}" fill="{colors["card_bg"]}" stroke="{colors["card_border"]}" rx="4"/>')

        # Platform header
        svg.append(f'<rect x="{x}" y="{y}" width="{card_width}" height="22" fill="{colors["header_bg"]}" rx="4"/>')
        svg.append(f'<rect x="{x}" y="{y + 18}" width="{card_width}" height="4" fill="{colors["header_bg"]}"/>')
        svg.append(f'<text x="{x + card_padding}" y="{y + 15}" class="platform-name">{platform_names.get(platform, platform)}</text>')

        row_y = y + 26
        arch_order = ['arm64-v8a', 'armeabi-v7a', 'arm64', 'x86_64', 'x86', 'x64']
        sorted_archs = sorted(archs.keys(), key=lambda a: arch_order.index(a) if a in arch_order else 99)

        for arch in sorted_archs:
            arts = archs[arch]
            baseline = next((a for a in arts if a.backend_key == 'xnnpack'), None)
            baseline_size = baseline.size_mb if baseline else 0

            # Arch label
            svg.append(f'<text x="{x + card_padding}" y="{row_y + 9}" class="arch-name">{arch}</text>')
            row_y += row_height

            # Sort by size, filter to meaningful single-backend additions only
            sorted_arts = sorted(arts, key=lambda a: a.size_mb)
            for artifact in sorted_arts:
                backend = artifact.backend_key
                size = artifact.size_mb
                delta = size - baseline_size

                # Only show: baseline OR single-backend additions with meaningful delta
                is_baseline = backend == 'xnnpack'
                is_single_addition = artifact.backend_count == 2 and 'xnnpack' in artifact.backends

                if not is_baseline and not (is_single_addition and delta > 0.5):
                    continue

                # Determine color and label based on the added backend
                if backend == 'xnnpack':
                    color = colors['xnnpack']
                    label = 'XNNPACK'
                elif 'vulkan' in artifact.backends:
                    color = colors['vulkan']
                    label = '+Vulkan'
                elif 'coreml' in artifact.backends:
                    color = colors['coreml']
                    label = '+CoreML'
                elif 'mps' in artifact.backends:
                    color = colors['mps']
                    label = '+MPS'
                else:
                    color = '#95a5a6'
                    label = backend

                # Bar
                bar_width = (size / max_size) * bar_max_width
                bar_x = x + card_padding
                svg.append(f'<rect x="{bar_x}" y="{row_y}" width="{bar_width}" height="{bar_height}" fill="{color}" rx="2"/>')

                # Label on bar
                if bar_width > 35:
                    svg.append(f'<text x="{bar_x + 3}" y="{row_y + 10}" class="bar-label">{label}</text>')

                # Size value
                value_x = bar_x + bar_max_width + 6
                svg.append(f'<text x="{value_x}" y="{row_y + 10}" class="size-value">{size:.1f} MB</text>')

                # Delta
                if not is_baseline and delta > 0.5:
                    delta_x = value_x + 42
                    svg.append(f'<text x="{delta_x}" y="{row_y + 10}" class="delta">+{delta:.1f}</text>')

                row_y += row_height

    # Note about excluded backends
    note_y = total_height - margin - 18
    svg.append(f'<text x="{margin}" y="{note_y}" class="note">* Backends with &lt;0.5 MB size impact and multi-backend combinations are excluded</text>')

    # Legend
    legend_y = total_height - margin
    legend_items = [
        (colors['xnnpack'], 'XNNPACK'),
        (colors['vulkan'], '+Vulkan'),
        (colors['coreml'], '+CoreML'),
        (colors['mps'], '+MPS'),
    ]
    legend_x = margin
    for color, label in legend_items:
        svg.append(f'<rect x="{legend_x}" y="{legend_y - 7}" width="8" height="8" fill="{color}" rx="1"/>')
        svg.append(f'<text x="{legend_x + 10}" y="{legend_y}" class="legend">{label}</text>')
        legend_x += 65

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

    assets = fetch_release_assets(tag, repo)
    artifacts = [parse_artifact_name(a['name'], a['size']) for a in assets]
    artifacts = [a for a in artifacts if a]

    print(f"Found {len(artifacts)} artifacts")

    if not artifacts:
        print("No artifacts found", file=sys.stderr)
        sys.exit(1)

    # Generate separate SVGs
    generate_svg(artifacts, 'release', tag, 'size-report-release.svg')
    generate_svg(artifacts, 'debug', tag, 'size-report-debug.svg')

    # Generate JSON report (all artifacts)
    report = {
        'release_tag': tag,
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'artifacts': {}
    }

    for a in artifacts:
        key = f"{a.build_type}/{a.platform}/{a.arch}/{a.backend_key}"
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
