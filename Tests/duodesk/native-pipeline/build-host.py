#!/usr/bin/env python3
"""Build the real production core plus an unadvertised loopback test entry point."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[3]
os.chdir(root)
out = root / '.build/native-pipeline'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['swift', 'build', '-c', 'release', '--product', 'SillMenuBar'], check=True)
products = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], text=True).strip())
intermediates = root / '.build/out/Intermediates.noindex/Sill.build/Release'
objects = [p for target in ['SillHostCore', 'StreamProtocol']
           for p in sorted((intermediates / f'{target}-t.build/Objects-normal/arm64').glob('*.o'))]
assert len(objects) > 90, 'Production swiftbuild objects were not found'
subprocess.run(['swiftc', '-package-name', root.name.lower(), '-I', str(products),
                str(root / 'Tests/duodesk/native-pipeline/main.swift'), *map(str, objects),
                '-o', str(out / 'Host')], check=True)
subprocess.run(['swiftc', str(root / 'Tests/duodesk/native-pipeline/Fixture.swift'), '-o', str(out / 'Fixture')], check=True)
