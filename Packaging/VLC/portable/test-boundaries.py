from pathlib import Path
import argparse,importlib.util,json,os,runpy,subprocess,sys,tempfile
E=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('portable_build',E/'build-vlc.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
checks=[]
for name in ['/etc/passwd','../escape','a/../../escape','./a','a//b']:
 try:m.safe_name(name)
 except RuntimeError:checks.append('rejected name '+name)
 else:raise RuntimeError('unsafe name accepted')
for name,target in [('a/link','/outside'),('a/link','../../outside')]:
 try:m.safe_link(name,target)
 except RuntimeError:checks.append('rejected symlink '+target)
 else:raise RuntimeError('unsafe symlink accepted')
if str(m.safe_name('prepared/vlckit/.git/HEAD'))!='prepared/vlckit/.git/HEAD' or m.safe_link('a/b/link','../header')!='a/header':raise RuntimeError('valid paths rejected')
with tempfile.TemporaryDirectory(prefix='shelf-vlc-portable-gates-') as value:
 root=Path(value).resolve();wrong=root/'wrong.tar';wrong.write_bytes(b'not the fixed material')
 try:m.load_materials(wrong)
 except RuntimeError as e:
  if 'SHA256 mismatch' not in str(e):raise
  checks.append('wrong material checksum rejected')
 else:raise RuntimeError('wrong material accepted')
 code="import runpy,sys;from pathlib import Path;m=runpy.run_path(sys.argv[1]);m['load_materials'](Path(sys.argv[2]))"
 p=subprocess.run(['/usr/bin/python3','-O','-I','-c',code,str(E/'build-vlc.py'),str(wrong)],capture_output=True,text=True)
 if p.returncode==0 or 'SHA256 mismatch' not in p.stderr:raise RuntimeError('optimization disabled checksum gate')
 checks.append('checksum gate stays active under -O -I')
 job=root/'arm64';tree=job/'vlckit';tree.mkdir(parents=True);(tree/'build').mkdir();m.Build.adapter(None,job,'arm64')
 for args in [['-version'],['archive'],['archive','ARCHS=x86_64']]:
  p=subprocess.run(['/usr/bin/python3','-I',str(job/'xcodebuild'),*args],cwd=tree,capture_output=True,text=True)
  if p.returncode==0 or 'PRIVATE_XCODEBUILD_REFUSED' not in p.stderr:raise RuntimeError('adapter invalid action accepted')
 checks.append('three invalid adapter actions rejected without Xcode execution')
 expected=['archive','-project','VLCKit.xcodeproj','-sdk','macosx','-configuration','Release','-scheme','VLCKit','-archivePath','build/VLCKit-macosx.xcarchive','ARCHS=arm64','IPHONEOS_DEPLOYMENT_TARGET=14.0','SKIP_INSTALL=no']
 original_exec=os.execv;original_args=sys.argv[:];original_cwd=Path.cwd();captured=[]
 class Captured(Exception):pass
 def capture(path,args):captured.append((path,args));raise Captured()
 try:
  os.execv=capture;sys.argv=[str(job/'xcodebuild'),*expected];os.chdir(tree)
  try:runpy.run_path(str(job/'xcodebuild'),run_name='adapter_plan')
  except Captured:pass
 finally:os.execv=original_exec;sys.argv=original_args;os.chdir(original_cwd)
 if len(captured)!=1 or not all(x in captured[0][1] for x in ['MACOSX_DEPLOYMENT_TARGET=14.0',str(job/'DerivedData'),'CLANG_MODULE_CACHE_PATH='+str(job/'ModuleCache'),'CODE_SIGNING_ALLOWED=NO']):raise RuntimeError('incorrect planned archive')
 checks.append('valid archive planned with private caches/macOS14/no signing; exec intercepted')
result={'status':'PASS','checks':checks,'actualXcodebuildExecuted':False,'actualBuildExecuted':False}
print(json.dumps(result,indent=2))
