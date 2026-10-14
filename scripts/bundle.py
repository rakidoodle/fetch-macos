#!/usr/bin/env python3
"""Build a self-contained, locally signed Apple Silicon Fetch app."""
import hashlib,json,os,pathlib,plistlib,re,shutil,subprocess,sys

ROOT=pathlib.Path(__file__).resolve().parents[1]
RELEASE=ROOT/'release'
APP=RELEASE/'Fetch.app'
RES=APP/'Contents/Resources'
BIN=RES/'Runtime/bin'
LIB=RES/'Runtime/lib'
CACHE=ROOT/'.build/runtime-assets'

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args],check=True,**kwargs)
def capture(args):
    return subprocess.check_output([str(x) for x in args],text=True)
def download(url,path):
    path.parent.mkdir(parents=True,exist_ok=True)
    run(['curl','-fL','--retry','2','--connect-timeout','20',url,'-o',path],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
def dependencies(file):
    return [line.strip().split(' (compatibility')[0] for line in capture(['otool','-L',file]).splitlines()[1:]]

RELEASE.mkdir(exist_ok=True)
# Preserve previous successful builds instead of destroying the only app on a failed rebuild.
if APP.exists():
    prior=RELEASE/'Fetch.previous.app'
    if prior.exists(): shutil.rmtree(prior)
    APP.rename(prior)
for d in [APP/'Contents/MacOS',BIN,LIB,RES/'backend',RES/'Licenses']: d.mkdir(parents=True,exist_ok=True)
sdk=os.environ.get('FETCH_BUILD_SDK','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
run(['swift','build','--build-system','native','--sdk',sdk,'-c','release'],cwd=ROOT)
shutil.copy2(ROOT/'.build/release/Fetch',APP/'Contents/MacOS/Fetch')
for item in ['server','node_modules']:
    shutil.copytree(ROOT/'backend'/item,RES/'backend'/item)
shutil.copy2(ROOT/'backend/package.json',RES/'backend/package.json')
for name in ['Help.html','AppIcon.icns','app-icon.png','empty-library.png','favicon.ico','favicon.png']:
    if (ROOT/'Assets'/name).exists():shutil.copy2(ROOT/'Assets'/name,RES/name)

# Copy the official Node arm64 executable and the locally installed download engines.
for command in ['node','aria2c','ffmpeg','ffprobe']:
    source=pathlib.Path(shutil.which(command) or '')
    if not source.is_file(): raise RuntimeError(f'{command} is required to build this bundle')
    shutil.copy2(source.resolve(),BIN/command)

# yt-dlp's Homebrew entry point depends on an external Python environment. Bundle its
# official universal macOS executable instead, verified against upstream SHA256SUMS.
manifest=CACHE/'yt-dlp-release.json'
if not manifest.exists():download('https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest',manifest)
release=json.loads(manifest.read_text());version=release['tag_name']
ytdlp=CACHE/f'yt-dlp_macos-{version}'
sums=CACHE/f'yt-dlp-SHA256SUMS-{version}'
if not sums.exists():download(f'https://github.com/yt-dlp/yt-dlp/releases/download/{version}/SHA2-256SUMS',sums)
if not ytdlp.exists():download(f'https://github.com/yt-dlp/yt-dlp/releases/download/{version}/yt-dlp_macos',ytdlp)
expected=next(line.split()[0] for line in sums.read_text().splitlines() if line.split()[-1]=='yt-dlp_macos')
assert hashlib.sha256(ytdlp.read_bytes()).hexdigest()==expected,'yt-dlp checksum mismatch'
shutil.copy2(ytdlp,BIN/'yt-dlp');(BIN/'yt-dlp').chmod(0o755)

# Relocate the full non-system dylib closure. All tools work with Homebrew absent.
copied={};queue=[(p,p) for p in BIN.iterdir() if p.name!='yt-dlp'];seen=set();min_version=(14,0)
while queue:
    source,target=queue.pop(0)
    if target in seen:continue
    seen.add(target)
    try:
        load=capture(['otool','-l',source])
        for value in re.findall(r'\bminos (\d+(?:\.\d+){0,2})',load):
            ver=tuple(map(int,value.split('.')));min_version=max(min_version,ver[:2] if len(ver)>1 else ver+(0,))
        for dep in dependencies(source):
            if dep.startswith('/System/') or dep.startswith('/usr/lib/'):continue
            if dep.startswith('@'):raise RuntimeError(f'Unresolved dynamic dependency: {source}: {dep}')
            actual=pathlib.Path(dep).resolve()
            if actual==source.resolve():continue
            name=actual.name
            if name in copied and copied[name]!=actual:raise RuntimeError(f'Dylib name collision: {actual}')
            dest=LIB/name
            if name not in copied:
                copied[name]=actual;shutil.copy2(actual,dest);dest.chmod(0o755);queue.append((actual,dest))
            location=('@loader_path/'+name) if target.parent==LIB else ('@loader_path/../lib/'+name)
            run(['install_name_tool','-change',dep,location,target],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        if target.parent==LIB:run(['install_name_tool','-id','@rpath/'+target.name,target],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:raise RuntimeError(f'Cannot relocate {target}: {error.stderr}')

# Re-sign relocated Mach-O binaries. The local build has no Developer ID notarization.
for target in list(LIB.iterdir())+list(BIN.iterdir()):
    run(['codesign','--force','--sign','-',target],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
minimum='.'.join(map(str,min_version))
info={
 'CFBundleExecutable':'Fetch','CFBundleName':'Fetch','CFBundleDisplayName':'Fetch',
 'CFBundleIdentifier':'com.nokit.fetch','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','CFBundleIconFile':'AppIcon',
 'LSMinimumSystemVersion':minimum,'NSHighResolutionCapable':True,
 'NSDownloadsFolderUsageDescription':'Fetch saves downloaded files in Downloads/Fetch.',
 'NSPrincipalClass':'NSApplication','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},
 'CFBundleURLTypes':[{'CFBundleURLName':'BitTorrent magnet','CFBundleURLSchemes':['magnet']}],
 'NSHumanReadableCopyright':'Fetch. Download engines retain their respective licenses.'
}
with open(APP/'Contents/Info.plist','wb') as f:plistlib.dump(info,f)
provenance={'minimum_macos':minimum,'architecture':'arm64','yt_dlp_version':version,'yt_dlp_sha256':expected,'node_version':capture([BIN/'node','--version']).strip(),'dylibs':{k:str(v) for k,v in copied.items()}}
(RES/'Licenses/runtime-manifest.json').write_text(json.dumps(provenance,indent=2)+'\n')
shutil.copy2(ROOT/'THIRD_PARTY.md',RES/'Licenses/THIRD_PARTY.md')
# Full license texts accompany the executables.
for name,url in {
 'Node-LICENSE.txt':'https://raw.githubusercontent.com/nodejs/node/v24.21.0/LICENSE',
 'aria2-COPYING.txt':'https://raw.githubusercontent.com/aria2/aria2/master/COPYING',
 'FFmpeg-COPYING.GPLv2.txt':'https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/COPYING.GPLv2',
 'FFmpeg-COPYING.GPLv3.txt':'https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/COPYING.GPLv3',
 'FFmpeg-COPYING.LGPLv2.1.txt':'https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/COPYING.LGPLv2.1',
 'yt-dlp-LICENSE.txt':f'https://raw.githubusercontent.com/yt-dlp/yt-dlp/{version}/LICENSE',
}.items():
 cache=CACHE/name
 if not cache.exists():download(url,cache)
 shutil.copy2(cache,RES/'Licenses'/name)
for command,args in [('node',['--version']),('aria2c',['--version']),('ffmpeg',['-version']),('ffprobe',['-version']),('yt-dlp',['--version'])]:
    output=capture([BIN/command]+args)
    print(command+': '+output.splitlines()[0])
run(['codesign','--force','--sign','-',APP],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
run(['codesign','--verify','--deep','--strict',APP],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
print(f'Built {APP}; Apple Silicon; macOS {minimum}+; {len(copied)} bundled dylibs')
