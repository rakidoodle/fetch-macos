#!/usr/bin/env python3
"""Create a separately identified native app for disposable UI verification."""
from pathlib import Path
import json,plistlib,shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
app=root/'.build/Fetch Verification.app'
if app.exists():shutil.rmtree(app)
shutil.copytree(root/'release/Fetch.app',app,symlinks=True)
storage=Path(tempfile.mkdtemp(prefix='fetch-verification-'))
p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
info.update(CFBundleIdentifier='com.nokit.fetch.verification',CFBundleName='Fetch Verification',CFBundleDisplayName='Fetch Verification',FetchVerificationDataDir=str(storage/'state'),FetchVerificationDownloadDir=str(storage/'files'))
p.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
(root/'.build/video-ui-app.json').write_text(json.dumps({'storage':str(storage),'app':str(app)}))
print('Created isolated Fetch Verification.app')
