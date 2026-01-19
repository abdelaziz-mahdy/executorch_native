#!/usr/bin/env python3
"""
Analyze ExecuTorch FFI build artifact sizes and generate SVG visualization.

Generates a single SVG with platform cards for both release and debug builds.
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


def generate_combined_svg(artifacts: List[ArtifactInfo], tag: str, output_path: str):
    """Generate combined SVG with release and debug sections."""

    # Platform display order and names
    platform_order = ['android', 'ios', 'ios-simulator', 'macos', 'linux', 'windows']
    platform_names = {
        'android': 'Android',
        'ios': 'iOS',
        'ios-simulator': 'iOS Sim',
        'macos': 'macOS',
        'linux': 'Linux',
        'windows': 'Windows'
    }

    # Colors
    colors = {
        'card_bg': '#ffffff',
        'card_border': '#e1e4e8',
        'header_bg': '#f6f8fa',
        'section_bg': '#eef1f4',
        'xnnpack': '#3498db',
        'vulkan': '#e67e22',
        'coreml': '#27ae60',
        'mps': '#9b59b6',
    }

    # Find global max for consistent scaling across both sections
    max_size = max(a.size_mb for a in artifacts)

    # Card dimensions
    card_width = 220
    card_padding = 10
    card_gap = 12
    row_height = 20
    bar_height = 12
    bar_max_width = 100
    section_padding = 15
    cols = 3

    margin = 16
    title_height = 35

    def calc_section_height(build_type: str) -> tuple:
        """Calculate section height and card data."""
        filtered = [a for a in artifacts if a.build_type == build_type]
        if not filtered:
            return 0, {}, {}

        # Group by platform, then by arch
        platforms: Dict[str, Dict[str, List[ArtifactInfo]]] = {}
        for a in filtered:
            if a.platform not in platforms:
                platforms[a.platform] = {}
            if a.arch not in platforms[a.platform]:
                platforms[a.platform][a.arch] = []
            platforms[a.platform][a.arch].append(a)

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
                    if a.backend_key == 'xnnpack' or (a.size_mb - baseline_size) > 0.5:
                        rows += 1
            card_heights[platform] = 32 + rows * row_height + card_padding

        # Calculate total section height
        current_x = 0
        max_row_height = 0
        section_height = 30  # section header

        for platform in sorted_platforms:
            h = card_heights[platform]
            if current_x + card_width > cols * (card_width + card_gap):
                current_x = 0
                section_height += max_row_height + card_gap
                max_row_height = 0
            max_row_height = max(max_row_height, h)
            current_x += card_width + card_gap

        section_height += max_row_height + section_padding

        return section_height, platforms, card_heights

    release_height, release_platforms, release_card_heights = calc_section_height('release')
    debug_height, debug_platforms, debug_card_heights = calc_section_height('debug')

    total_width = margin * 2 + cols * card_width + (cols - 1) * card_gap
    total_height = title_height + release_height + debug_height + margin + 25  # +25 for legend

    # Build SVG
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total_width} {total_height}">',
        '<style>',
        '  .title { font: bold 13px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .section-title { font: bold 11px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .platform-name { font: bold 10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .arch-name { font: 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #586069; }',
        '  .size-value { font: 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .delta { font: 8px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #22863a; }',
        '  .bar-label { font: 7px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: white; }',
        '  .legend { font: 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #586069; }',
        '</style>',
        f'<rect width="{total_width}" height="{total_height}" fill="#f6f8fa"/>',
        f'<text x="{total_width/2}" y="22" text-anchor="middle" class="title">ExecuTorch Library Sizes ({tag})</text>',
    ]

    def draw_section(build_type: str, platforms_data: Dict, card_heights: Dict, start_y: float):
        """Draw a section (release or debug)."""
        if not platforms_data:
            return

        sorted_platforms = sorted(platforms_data.keys(),
            key=lambda p: platform_order.index(p) if p in platform_order else 99)

        # Section header
        svg.append(f'<text x="{margin}" y="{start_y + 18}" class="section-title">{build_type.upper()}</text>')

        current_x = margin
        current_y = start_y + 28
        max_row_height = 0

        for platform in sorted_platforms:
            h = card_heights[platform]
            archs = platforms_data[platform]

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
            svg.append(f'<rect x="{x}" y="{y}" width="{card_width}" height="24" fill="{colors["header_bg"]}" rx="4"/>')
            svg.append(f'<rect x="{x}" y="{y + 20}" width="{card_width}" height="4" fill="{colors["header_bg"]}"/>')
            svg.append(f'<text x="{x + card_padding}" y="{y + 16}" class="platform-name">{platform_names.get(platform, platform)}</text>')

            row_y = y + 30
            arch_order = ['arm64-v8a', 'armeabi-v7a', 'arm64', 'x86_64', 'x86', 'x64']
            sorted_archs = sorted(archs.keys(), key=lambda a: arch_order.index(a) if a in arch_order else 99)

            for arch in sorted_archs:
                arts = archs[arch]
                baseline = next((a for a in arts if a.backend_key == 'xnnpack'), None)
                baseline_size = baseline.size_mb if baseline else 0

                # Arch label
                svg.append(f'<text x="{x + card_padding}" y="{row_y + 9}" class="arch-name">{arch}</text>')
                row_y += row_height

                sorted_arts = sorted(arts, key=lambda a: a.size_mb)
                for artifact in sorted_arts:
                    backend = artifact.backend_key
                    size = artifact.size_mb
                    delta = size - baseline_size if baseline_size else 0

                    if backend != 'xnnpack' and delta <= 0.5:
                        continue

                    # Determine color and label
                    if backend == 'xnnpack':
                        color = colors['xnnpack']
                        label = 'XNNPACK'
                    elif 'vulkan' in backend:
                        color = colors['vulkan']
                        label = '+Vulkan'
                    elif 'mps' in backend and 'coreml' in backend:
                        color = colors['mps']
                        label = '+C+M'
                    elif 'coreml' in backend:
                        color = colors['coreml']
                        label = '+CoreML'
                    elif 'mps' in backend:
                        color = colors['mps']
                        label = '+MPS'
                    else:
                        color = '#95a5a6'
                        label = '+'

                    # Bar
                    bar_width = (size / max_size) * bar_max_width
                    bar_x = x + card_padding
                    svg.append(f'<rect x="{bar_x}" y="{row_y}" width="{bar_width}" height="{bar_height}" fill="{color}" rx="2"/>')

                    # Label on bar
                    if bar_width > 30:
                        svg.append(f'<text x="{bar_x + 3}" y="{row_y + 9}" class="bar-label">{label}</text>')

                    # Size value
                    value_x = bar_x + bar_max_width + 6
                    svg.append(f'<text x="{value_x}" y="{row_y + 9}" class="size-value">{size:.1f}</text>')

                    # Delta
                    if backend != 'xnnpack' and delta > 0.5:
                        delta_x = value_x + 28
                        svg.append(f'<text x="{delta_x}" y="{row_y + 9}" class="delta">+{delta:.0f}</text>')

                    row_y += row_height

    # Draw sections
    draw_section('release', release_platforms, release_card_heights, title_height)
    draw_section('debug', debug_platforms, debug_card_heights, title_height + release_height)

    # Legend
    legend_y = total_height - 12
    legend_items = [
        (colors['xnnpack'], 'XNNPACK'),
        (colors['vulkan'], '+Vulkan'),
        (colors['coreml'], '+CoreML'),
        (colors['mps'], '+MPS'),
    ]
    legend_x = margin
    for color, label in legend_items:
        svg.append(f'<rect x="{legend_x}" y="{legend_y - 7}" width="8" height="8" fill="{color}" rx="1"/>')
        svg.append(f'<text x="{legend_x + 11}" y="{legend_y}" class="legend">{label}</text>')
        legend_x += 70

    svg.append(f'<text x="{total_width - margin}" y="{legend_y}" text-anchor="end" class="legend">Sizes in MB</text>')

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

    # Generate single combined SVG
    generate_combined_svg(artifacts, tag, 'size-report.svg')

    # Generate JSON report
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
