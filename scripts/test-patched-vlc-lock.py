#!/usr/bin/python3 -I
"""Private positive/negative tests; never install a framework or change the active lock."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, re, shutil, subprocess

PROJECT=Path(__file__).resolve().parent.parent

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['package','receipt','materials','work','test-root']:p.add_argument('--'+name,type=Path,required=True)
    args=p.parse_args();root=args.test_root.resolve()
    if root.exists():raise RuntimeError('Test root must be new')
    root.mkdir();rows=[]
    protected=[PROJECT/'Packaging/VLC/patched-lock.json',PROJECT/'Sources/ShelfPlayback/NativePCMCompatibilityEngine.swift',PROJECT/'Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit']
    before={str(f):sha(f) for f in protected}
    generator=PROJECT/'scripts/create-patched-vlc-lock.py'
    def invoke(name,package=args.package,receipt=args.receipt,output=None,success=False):
        target=output or root/(name+'.candidate.json')
        command=['/usr/bin/python3','-I',str(generator),'--package',str(package),'--receipt',str(receipt),'--materials',str(args.materials),'--work',str(args.work),'--output',str(target)]
        r=subprocess.run(command,cwd=PROJECT,capture_output=True,text=True,timeout=180)
        (root/(name+'.log')).write_text(r.stdout+r.stderr)
        if (r.returncode==0)!=success:raise RuntimeError(name+' unexpected exit '+str(r.returncode))
        if not success and output is None and target.exists():raise RuntimeError(name+' left a candidate after rejection')
        rows.append({'name':name,'exit':r.returncode,'expectedSuccess':success,'command':command})
        return target
    def clone(name):
        target=root/name/'VLCKit.xcframework';target.parent.mkdir()
        subprocess.run(['/bin/cp','-cR',str(args.package.resolve()),str(target)],check=True)
        original=args.package/'macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit';copied=target/'macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit'
        if original.stat().st_ino==copied.stat().st_ino:raise RuntimeError('Disposable copy shares inode')
        return target
    candidate=invoke('actual-current-package',success=True)
    value=json.loads(candidate.read_text())
    if value['candidateReview']['status']!='GENERATED_NOT_ACTIVATED' or len(value['candidateReview']['actualRuntimeRuns'])!=2:raise RuntimeError('Missing actual runtime evidence')
    sentinel=root/'existing.candidate.json';sentinel.write_text('do not overwrite')
    invoke('overwrite-refused',output=sentinel)
    if sentinel.read_text()!='do not overwrite':raise RuntimeError('Overwrite occurred')
    escaped=clone('escaping-link');link=escaped/'macos-arm64_x86_64/VLCKit.framework/Versions/Current';link.unlink();link.symlink_to('/usr/lib',target_is_directory=True)
    invoke('external-link-refused',package=escaped);shutil.rmtree(escaped.parent)
    single=clone('missing-architecture');info=single/'Info.plist';data=plistlib.loads(info.read_bytes());data['AvailableLibraries'][0]['SupportedArchitectures']=['arm64'];info.write_bytes(plistlib.dumps(data))
    invoke('missing-slice-refused',package=single);shutil.rmtree(single.parent)
    wrong=clone('wrong-dsym');dwarf=wrong/'macos-arm64_x86_64/dSYMs/VLCKit.framework.dSYM/Contents/Resources/DWARF/VLCKit'
    original_uuid=subprocess.run(['/usr/bin/dwarfdump','--uuid',str(dwarf)],check=True,capture_output=True,text=True).stdout
    uuid=bytes.fromhex(re.search(r'UUID: ([A-Fa-f0-9-]+)',original_uuid).group(1).replace('-',''));data=dwarf.read_bytes();offset=data.find(uuid)
    if offset<0:raise RuntimeError('dSYM UUID not found')
    changed=bytearray(data);changed[offset]^=1;dwarf.write_bytes(changed)
    altered_uuid=subprocess.run(['/usr/bin/dwarfdump','--uuid',str(dwarf)],check=True,capture_output=True,text=True).stdout
    if altered_uuid==original_uuid:raise RuntimeError('dSYM fault injection ineffective')
    invoke('wrong-dsym-refused',package=wrong);shutil.rmtree(wrong.parent)
    false_receipt=root/'wrong-receipt.json';data=json.loads(args.receipt.read_text());data['combined']['binarySHA256']='0'*64;false_receipt.write_text(json.dumps(data))
    invoke('receipt-not-substitute-for-package',receipt=false_receipt)
    after={str(f):sha(f) for f in protected}
    if after!=before:raise RuntimeError('Active project input changed')
    result={'status':'PASS','tests':rows,'protectedBefore':before,'protectedAfter':after,'generatorSHA256':sha(generator),'testSHA256':sha(Path(__file__)),'candidateSHA256':sha(candidate),'activeLockVendorRuntimeUnchanged':True,'productTestsRun':False}
    (root/'Results.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS '+str(len(rows))+' candidate-lock tests; active lock/Vendor/runtime unchanged')

if __name__=='__main__':main()
