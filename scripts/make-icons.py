#!/usr/bin/env python3
"""Convert the generated master into standard app-icon and favicon formats."""
from pathlib import Path
import subprocess
from PIL import Image
root=Path(__file__).resolve().parents[1]
assets=root/'Assets';icon=Image.open(assets/'app-icon.png').convert('RGBA')
iconset=assets/'AppIcon.iconset';iconset.mkdir(exist_ok=True)
for size in [16,32,128,256,512]:
    for scale in [1,2]:
        pixels=size*scale
        name=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
        icon.resize((pixels,pixels),Image.Resampling.LANCZOS).save(iconset/name)
icon.resize((64,64),Image.Resampling.LANCZOS).save(assets/'favicon.png')
icon.save(assets/'favicon.ico',format='ICO',sizes=[(16,16),(32,32),(48,48),(64,64)])
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(assets/'AppIcon.icns')],check=True)
print('AppIcon.icns and 16–1024px iconset, favicon.ico and favicon.png created')
