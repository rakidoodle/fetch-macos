#!/usr/bin/env python3
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
app=root/'release/Fetch.app'
files=[app/'Contents/MacOS/Fetch',*list((app/'Contents/Resources/Runtime/bin').iterdir()),*list((app/'Contents/Resources/Runtime/lib').iterdir())]
for file in files:
    arch=subprocess.check_output(['lipo','-archs',str(file)],text=True).strip()
    assert 'arm64' in arch,(file.name,arch)
    lines=subprocess.check_output(['otool','-L',str(file)],text=True).splitlines()
    dependencies=[s.strip().split(' (compatibility')[0] for s in lines if ' (compatibility' in s]
    assert all(s.startswith(('/System/','/usr/lib/','@')) for s in dependencies),(file.name,dependencies)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print(f'PASS: {len(files)} Mach-O files contain arm64; no external non-system dylib dependencies; full signature verified.')
