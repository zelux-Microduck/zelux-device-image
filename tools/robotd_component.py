#!/usr/bin/env python3
"""Consume a separately built, hash-pinned ARM64 robotd delivery directory.

No downloads, compilation, hooks, service activation or motion commands.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

MANIFEST = 'robotd-component.json'
SCHEMA = 'zelux.robotd-component/v1'
REQUIRED = ('bin/robotd', 'bin/robotctl', 'systemd/robotd.service',
            'config/robotd.toml', 'lib/libonnxruntime.so')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def elf(path):
    header = path.read_bytes()[:20]
    if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack('<H', header[18:20])[0] != 183:
        raise ValueError(f'not an ARM64 little-endian ELF: {path}')


def files(directory):
    result = {}
    for item in directory.rglob('*'):
        if item.is_symlink():
            raise ValueError(f'symlinks are not allowed in delivery directory: {item}')
        if not item.is_dir() and not item.is_file():
            raise ValueError(f'unsupported delivery file type: {item}')
        if item.is_file() and item.relative_to(directory).as_posix() != MANIFEST:
            result[item.relative_to(directory).as_posix()] = digest(item)
    return result


def verify(directory):
    data = json.loads((directory / MANIFEST).read_text('utf-8'))
    if data.get('schema') != SCHEMA or not re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?', data.get('version', '')):
        raise ValueError('invalid robotd component schema/version')
    if not data.get('source_revision') or not data.get('source'):
        raise ValueError('source and source_revision are required')
    if directory.is_symlink():
        raise ValueError('delivery root must not be a symlink')
    if data.get('files') != files(directory):
        raise ValueError('robotd delivery file hashes do not match manifest')
    for name in REQUIRED:
        if name not in data['files']:
            raise ValueError(f'missing required robotd artifact: {name}')
    for item in (directory / 'bin').iterdir():
        if item.is_file():
            elf(item)
    for item in (directory / 'lib').iterdir():
        if item.is_file():
            elf(item)
    service = (directory / 'systemd/robotd.service').read_text('utf-8')
    if 'ExecStart=/opt/robot/daemon/current/bin/robotd' not in service or 'Group=robot' not in service:
        raise ValueError('robotd service does not use native release layout / robot group')
    return data


def locked(directory, lock):
    values = {}
    for line in lock.read_text('utf-8').splitlines():
        if ':' in line and not line.startswith('#'):
            key, value = line.split(':', 1)
            values[key] = value.strip()
    data = verify(directory)
    if values.get('robotd') != data['version'] or values.get('robotd_manifest_sha256') != digest(directory / MANIFEST):
        raise ValueError('robotd release is not pinned by components.lock.yaml; assemble with --lock first')
    return data


def assemble(source, expected, output, lock):
    if not re.fullmatch('[0-9a-f]{64}', expected) or digest(source / MANIFEST) != expected:
        raise ValueError('trusted robotd manifest SHA-256 mismatch')
    data = verify(source)
    if output.exists():
        raise ValueError(f'output exists: {output}; select a new output directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, output)
    if lock:
        lines = [line for line in lock.read_text('utf-8').splitlines()
                 if not line.startswith(('motiond:', 'robotd:', 'robotd_manifest_sha256:'))]
        lines += [f"robotd: {data['version']}", f'robotd_manifest_sha256: {expected}']
        lock.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')


def check_runtime(source, root, lock):
    locked(source, lock)
    # Dynamic linking is checked against the target root, never by executing ARM
    # binaries on a build host. readelf failure is not treated as success.
    system_libs = [root / p for p in ('lib', 'usr/lib', 'lib64', 'usr/lib64')]
    bundled = {p.name for p in (source / 'lib').iterdir()}
    for binary in list((source / 'bin').iterdir()) + list((source / 'lib').iterdir()):
        if not binary.is_file():
            continue
        dynamic = subprocess.run(['readelf', '-d', str(binary)], check=True,
                                 text=True, capture_output=True).stdout
        for needed in re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic):
            if needed not in bundled and not any(any(p.rglob(needed)) for p in system_libs if p.exists()):
                raise ValueError(f'{binary.name}: target root missing runtime dependency {needed}')


def install(source, root, lock):
    data = locked(source, lock)
    check_runtime(source, root, lock)
    daemon = root / 'opt/robot/daemon'
    releases = daemon / 'releases'
    releases.mkdir(parents=True, exist_ok=True)
    target = releases / data['version']
    if target.exists():
        verify(target)
        if digest(target / MANIFEST) != digest(source / MANIFEST):
            raise ValueError('installed robotd version has different contents; publish a new version')
    else:
        stage = Path(tempfile.mkdtemp(prefix='.robotd-', dir=releases))
        try:
            # Keep every hashed file, including runtime provenance and licenses.
            shutil.copytree(source, stage, dirs_exist_ok=True)
            for binary in (stage / 'bin').iterdir():
                binary.chmod(0o755)
            stage.rename(target)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    # Preserve existing user configuration. Do not default to a new bus protocol.
    config = root / 'etc/robot/robotd.toml'
    config.parent.mkdir(parents=True, exist_ok=True)
    if not config.exists():
        shutil.copy2(source / 'config/robotd.toml', config)
    units = root / 'etc/systemd/system'
    units.mkdir(parents=True, exist_ok=True)
    # Atomic replacement also replaces an old /dev/null mask, never follows it.
    service_temp = units / '.robotd.service-zelux'
    shutil.copy2(source / 'systemd/robotd.service', service_temp)
    os.replace(service_temp, units / 'robotd.service')
    dropin = units / 'robotd.service.d'
    dropin.mkdir(exist_ok=True)
    (dropin / '20-zelux-runtime.conf').write_text(
        '[Unit]\nAfter=zeluxd.service\n[Service]\n'
        'Environment=ORT_DYLIB_PATH=/opt/robot/daemon/current/lib/libonnxruntime.so\n'
        'Environment=LD_LIBRARY_PATH=/opt/robot/daemon/current/lib\n', encoding='utf-8')
    sysusers = root / 'usr/lib/sysusers.d'
    sysusers.mkdir(parents=True, exist_ok=True)
    (sysusers / 'zelux-robot.conf').write_text('g robot -\n', encoding='utf-8')
    current = daemon / 'current'
    if current.exists() and not current.is_symlink():
        raise ValueError('refusing to replace non-symlink robotd current')
    temp = daemon / '.current-zelux'
    if temp.is_symlink():
        temp.unlink()
    temp.symlink_to('releases/' + data['version'], target_is_directory=True)
    os.replace(temp, current)
    # robotctl inherits runtime dependencies without changing global ld.so paths.
    cli = root / 'usr/local/bin/robotctl'
    cli.parent.mkdir(parents=True, exist_ok=True)
    cli.write_text('#!/bin/sh\nexport ORT_DYLIB_PATH=/opt/robot/daemon/current/lib/libonnxruntime.so\n'
                   'export LD_LIBRARY_PATH=/opt/robot/daemon/current/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n'
                   'exec /opt/robot/daemon/current/bin/robotctl "$@"\n', encoding='utf-8', newline='\n')
    cli.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('op', choices=['seal', 'assemble', 'verify', 'check-runtime', 'install'])
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--manifest-sha256')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--lock', type=Path, required=True)
    parser.add_argument('--version')
    parser.add_argument('--source-revision')
    parser.add_argument('--origin')
    args = parser.parse_args()
    if args.op == 'seal':
        if not args.version or not args.source_revision or not args.origin:
            parser.error('seal requires --version, --source-revision, --origin')
        manifest = args.source / MANIFEST
        manifest.write_text(json.dumps(dict(schema=SCHEMA, version=args.version,
            source_revision=args.source_revision, source=args.origin, files=files(args.source)),
            ensure_ascii=False, sort_keys=True, indent=2) + '\n', encoding='utf-8')
        verify(args.source)
        print(digest(manifest))
    elif args.op == 'assemble':
        if not args.output or not args.manifest_sha256:
            parser.error('assemble requires --output and trusted --manifest-sha256')
        assemble(args.source, args.manifest_sha256, args.output, args.lock)
    elif args.op == 'verify':
        locked(args.source, args.lock)
    else:
        if not args.root:
            parser.error('install requires --root')
        if args.op == 'check-runtime':
            check_runtime(args.source, args.root, args.lock)
        else:
            install(args.source, args.root, args.lock)


if __name__ == '__main__':
    main()
