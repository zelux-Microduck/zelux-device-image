#!/usr/bin/env python3
"""Package already cross-built robotd binaries with a SHA-pinned native ORT wheel.

Does not download, compile, install Python packages or execute target code.
"""
import argparse
import hashlib
import json
import shutil
import tarfile
import zipfile
from pathlib import Path
import robotd_component as component


def package(args):
    if args.output.exists():
        raise ValueError('output exists; choose a new release directory')
    if component.digest(args.runtime_wheel) != args.runtime_sha256:
        raise ValueError('ONNX Runtime wheel SHA-256 mismatch')
    if 'aarch64' not in args.runtime_wheel.name:
        raise ValueError('ONNX Runtime wheel must be aarch64')
    binary_dir = args.target / 'aarch64-unknown-linux-gnu/release'
    for name in ('robotd', 'robotctl'):
        component.elf(binary_dir / name)
    metadata = __import__('tomllib').loads((args.source / 'Cargo.toml').read_text())
    runtime = metadata['workspace']['metadata']['onnxruntime']['target']
    if not args.runtime_wheel.name.startswith('onnxruntime-' + runtime + '-'):
        raise ValueError('wheel version does not match robotd ONNX target pin')
    args.output.mkdir(parents=True)
    for folder in ('bin', 'lib', 'systemd', 'config', 'licenses'):
        (args.output / folder).mkdir()
    for name in ('robotd', 'robotctl'):
        shutil.copy2(binary_dir / name, args.output / 'bin' / name)
    shutil.copy2(args.source / 'robotd/systemd/robotd.service', args.output / 'systemd/robotd.service')
    shutil.copy2(args.config, args.output / 'config/robotd.toml')
    with zipfile.ZipFile(args.runtime_wheel) as wheel:
        libraries = []
        for name in wheel.namelist():
            base = name.rsplit('/', 1)[-1]
            # Explicit allowlist, no archive paths are used as output paths.
            if name.startswith('onnxruntime/capi/') and base.startswith('libonnxruntime') and '.so' in base:
                data = wheel.read(name)
                dest = args.output / 'lib' / base
                dest.write_bytes(data)
                component.elf(dest)
                if base == 'libonnxruntime.so.' + runtime:
                    shutil.copy2(dest, args.output / 'lib/libonnxruntime.so')
                    shutil.copy2(dest, args.output / 'lib/libonnxruntime.so.1')
                libraries.append(base)
            elif base in ('LICENSE', 'LICENSE.txt', 'ThirdPartyNotices.txt'):
                (args.output / 'licenses' / ('onnxruntime-' + base)).write_bytes(wheel.read(name))
    provenance = dict(version=runtime, wheel=args.runtime_wheel.name,
                      sha256=args.runtime_sha256, url=args.runtime_url, libraries=libraries)
    (args.output / 'onnxruntime-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    manifest = dict(schema=component.SCHEMA, version=args.version,
                    source=args.origin, source_revision=args.revision, files=component.files(args.output))
    (args.output / component.MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    component.verify(args.output)
    archive = args.output.with_name(args.output.name + '.tar.gz')
    with tarfile.open(archive, 'w:gz') as tar:
        tar.add(args.output, arcname=args.output.name)
    print(json.dumps(dict(directory=str(args.output), archive=str(archive),
        archive_sha256=component.digest(archive), manifest_sha256=component.digest(args.output / component.MANIFEST)), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'target', 'output', 'config', 'runtime-wheel'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('version', 'revision', 'origin', 'runtime-sha256', 'runtime-url'):
        parser.add_argument('--' + name, required=True)
    package(parser.parse_args())
