#!/usr/bin/env python3
"""Extract SHA-verified Debian ARM64 runtime packages into a NEW test directory.

No package installation, global apt changes, sudo or target services.
"""
import argparse
import hashlib
import json
import lzma
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--mirror', default='https://deb.debian.org/debian/')
args = parser.parse_args()
if args.output.exists():
    parser.error('output must not already exist')
args.output.mkdir(parents=True)
base = args.mirror.rstrip('/') + '/'
index = args.output / 'Packages.xz'
subprocess.run(['curl', '-fL', '--max-time', '60', '-o', str(index),
                base + 'dists/trixie/main/binary-arm64/Packages.xz'], check=True)
packages = {}
for block in lzma.decompress(index.read_bytes()).decode().split('\n\n'):
    fields = dict(line.split(': ', 1) for line in block.splitlines() if ': ' in line and not line.startswith(' '))
    if fields.get('Package') in ('libc6', 'libgcc-s1', 'libstdc++6'):
        packages[fields['Package']] = fields
if len(packages) != 3:
    raise RuntimeError('runtime package index incomplete')
provenance = []
for name, item in packages.items():
    archive = args.output / (name + '.deb')
    url = base + item['Filename']
    subprocess.run(['curl', '-fL', '--max-time', '60', '-o', str(archive), url], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != item['SHA256']:
        raise RuntimeError('Debian package SHA mismatch: ' + name)
    subprocess.run(['dpkg-deb', '-x', str(archive), str(args.output)], check=True)
    provenance.append(dict(package=name, version=item['Version'], url=url, sha256=item['SHA256']))
(args.output / 'lib').symlink_to('usr/lib', target_is_directory=True)
(args.output / 'runtime-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
