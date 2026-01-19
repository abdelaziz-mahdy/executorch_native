#!/usr/bin/env python3
"""
Analyze ExecuTorch FFI build artifact sizes and generate SVG visualizations.

Generates compact text-list SVGs for release and debug builds.
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
    """Generate compact text-list SVG."""
    filtered = [a for a in artifacts if a.build_type == build_type]
    if not filtered:
        print(f"No {build_type} artifacts found, skipping")
        return

    # Platform display order and names
    platform_order = ['android', 'ios', 'ios-simulator', 'macos', 'linux', 'windows']
    platform_names = {
        'android': 'ANDROID',
        'ios': 'iOS',
        'ios-simulator': 'iOS SIMULATOR',
        'macos': 'macOS',
        'linux': 'LINUX',
        'windows': 'WINDOWS'
    }

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

    # Build content lines
    lines = []

    for platform in sorted_platforms:
        archs = platforms[platform]
        arch_order = ['arm64-v8a', 'armeabi-v7a', 'arm64', 'x86_64', 'x86', 'x64']
        sorted_archs = sorted(archs.keys(), key=lambda a: arch_order.index(a) if a in arch_order else 99)

        # Platform header
        lines.append(('header', platform_names.get(platform, platform)))

        for arch in sorted_archs:
            arts = archs[arch]
            baseline = next((a for a in arts if a.backend_key == 'xnnpack'), None)
            baseline_size = baseline.size_mb if baseline else 0

            # Get single-backend additions
            additions = []
            for a in sorted(arts, key=lambda x: x.size_mb):
                if a.backend_key == 'xnnpack':
                    continue
                if a.backend_count == 2 and 'xnnpack' in a.backends:
                    # Determine backend name
                    other = [b for b in a.backends if b != 'xnnpack'][0]
                    delta = a.size_mb - baseline_size
                    additions.append((other, a.size_mb, delta))

            lines.append(('arch', arch, baseline_size, additions))

    # Calculate SVG dimensions
    margin = 16
    line_height = 16
    header_height = 22

    # Count lines
    total_height = 36  # title
    for line in lines:
        if line[0] == 'header':
            total_height += header_height
        else:
            total_height += line_height
    total_height += 24  # footer note

    width = 580

    # Build SVG
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {total_height}">',
        '<style>',
        '  .title { font: bold 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #24292e; }',
        '  .header { font: bold 10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #0969da; }',
        '  .arch { font: 10px monospace; fill: #24292e; }',
        '  .size { font: 10px monospace; fill: #24292e; }',
        '  .backend { font: 10px monospace; fill: #57606a; }',
        '  .delta { font: 10px monospace; fill: #1a7f37; }',
        '  .delta-zero { font: 10px monospace; fill: #8b949e; }',
        '  .note { font: italic 9px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; fill: #6e7781; }',
        '</style>',
        f'<rect width="{width}" height="{total_height}" fill="#ffffff"/>',
        f'<text x="{margin}" y="24" class="title">{build_type.capitalize()} Build Sizes ({tag})</text>',
    ]

    y = 44

    for line in lines:
        if line[0] == 'header':
            svg.append(f'<text x="{margin}" y="{y + 12}" class="header">{line[1]}</text>')
            y += header_height
        else:
            _, arch, baseline_size, additions = line

            # Format: "  arch:  XX.X MB  │ +Backend: XX.X (+X.X) │ ..."
            text_parts = []

            # Arch and baseline
            arch_display = arch.replace('arm64-v8a', 'arm64').replace('armeabi-v7a', 'armv7').replace('x86_64', 'x64')
            text_parts.append(f'<tspan class="arch">{arch_display:>6}</tspan>')
            text_parts.append(f'<tspan class="size" dx="8">{baseline_size:>5.1f} MB</tspan>')

            # Additions
            for backend, size, delta in additions:
                backend_short = backend.capitalize()
                if delta > 0.5:
                    text_parts.append(f'<tspan class="backend" dx="12">+{backend_short}:</tspan>')
                    text_parts.append(f'<tspan class="size">{size:>5.1f}</tspan>')
                    text_parts.append(f'<tspan class="delta">(+{delta:.1f})</tspan>')
                else:
                    text_parts.append(f'<tspan class="backend" dx="12">+{backend_short}:</tspan>')
                    text_parts.append(f'<tspan class="delta-zero">~0</tspan>')

            svg.append(f'<text x="{margin + 8}" y="{y + 11}">{"".join(text_parts)}</text>')
            y += line_height

    # Note
    svg.append(f'<text x="{margin}" y="{total_height - 8}" class="note">* Multi-backend combinations excluded. ~0 = negligible size difference.</text>')

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
