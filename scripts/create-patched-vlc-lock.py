#!/usr/bin/python3 -I
"""Generate an independent candidate lock for the same fixed sources; never activate it."""
from pathlib import Path
import argparse, copy, hashlib, importlib.util, json, math, os, plistlib, stat, struct, tempfile, wave, sys, subprocess
from types import SimpleNamespace

PROJECT = Path(__file__).resolve().parent.parent
PORTABLE = PROJECT / 'Packaging/VLC/portable'
RECIPE_SHA = '975ce67dc44d9fc9366539e42d663a1fa458471c039f36dc880f01a3b7395a7a'
CAPTURE_SHA = '80056257ece6678aeb104d008ca995b38c0c9a5a851629ae820dc64a78372066'

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def inventory(package):
    rows={}
    for p in sorted(package.rglob('*')):
        name=str(p.relative_to(package))
        if p.is_symlink():
            if not p.resolve().is_relative_to(package) or not p.resolve().exists():raise RuntimeError('Escaping or broken package link: '+name)
            rows[name]={'symlink':os.readlink(p)}
        elif p.is_file():rows[name]={'bytes':p.stat().st_size,'sha256':sha(p),'mode':stat.S_IMODE(p.stat().st_mode)}
        elif not p.is_dir():raise RuntimeError('Special package entry: '+name)
    return rows

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['package','receipt','materials','work','output']:parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    if args.package.is_symlink():raise RuntimeError('Package root must not be a symlink')
    package=args.package.resolve();work=args.work.resolve();output=args.output.absolute()
    if not output.name.endswith('.candidate.json') or os.path.lexists(output):raise RuntimeError('Output must be a new .candidate.json; overwrite is forbidden')
    if not output.parent.is_dir():raise RuntimeError('Output parent must exist')
    output=output.parent.resolve()/output.name
    if output.is_relative_to(package) or output.is_relative_to(work):raise RuntimeError('Output must be outside input package/work trees')
    if sha(PORTABLE/'build-vlc.py')!=RECIPE_SHA or sha(PORTABLE/'direct-tail.c')!=CAPTURE_SHA:raise RuntimeError('Reviewed fixed recipe/capture changed')
    seed=json.loads((PROJECT/'Packaging/VLC/patched-lock.json').read_text())
    before=inventory(package)
    if set(before)!=set(seed['packageFiles']):raise RuntimeError('Unexpected package file membership')
    for name,row in before.items():
        if 'symlink' in row and row!=seed['packageFiles'][name]:raise RuntimeError('Unexpected package symlink layout')
    if not package.is_dir() or not before:raise RuntimeError('Package missing')
    info=plistlib.loads((package/'Info.plist').read_bytes());libraries=info['AvailableLibraries']
    if len(libraries)!=1:raise RuntimeError('Expected one macOS variant')
    library=libraries[0]
    if library['SupportedPlatform']!='macos' or set(library['SupportedArchitectures'])!={'arm64','x86_64'} or library.get('SupportedPlatformVariant'):raise RuntimeError('Expected both macOS architectures')
    if library['LibraryIdentifier']!='macos-arm64_x86_64' or library['LibraryPath']!='VLCKit.framework' or library['DebugSymbolsPath']!='dSYMs':raise RuntimeError('Unexpected package layout')
    framework=package/'macos-arm64_x86_64/VLCKit.framework';dsym=package/'macos-arm64_x86_64/dSYMs/VLCKit.framework.dSYM';binary=framework/'Versions/A/VLCKit'
    receipt_bytes=args.receipt.read_bytes();receipt=json.loads(receipt_bytes)
    if receipt.get('status')!='PASS' or receipt.get('recipeSHA256')!=RECIPE_SHA or receipt.get('smokeSourceSHA256')!=CAPTURE_SHA or receipt.get('requestedArchitecture')!='universal':raise RuntimeError('Fixed-source universal receipt required')
    stages=receipt.get('stages',[])
    if len(stages)!=44 or len({s['name'] for s in stages})!=44 or any(s.get('exit')!=0 for s in stages):raise RuntimeError('Receipt must contain 44 successful stages')
    if not {'arm64-build','x86_64-build','package','combined-arm64-smoke-run','combined-x86_64-smoke-run'}.issubset({s['name'] for s in stages}):raise RuntimeError('Required receipt stages missing')
    sys.dont_write_bytecode=True
    spec=importlib.util.spec_from_file_location('fixed_builder',PORTABLE/'build-vlc.py');builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
    inputs=builder.load_materials(args.materials.resolve())
    if receipt.get('configurationPolicyID')!=builder.POLICY_ID or receipt.get('expectedPluginEntries')!=sorted(builder.EXPECTED_PLUGIN_ENTRIES) or receipt.get('excludedPluginEntries')!=sorted(builder.EXCLUDED_PLUGIN_ENTRIES):raise RuntimeError('Candidate plugin policy receipt mismatch')
    for arch in ['arm64','x86_64']:
        builder.validate_plugin_header((framework/('Versions/A/PrivateHeaders/vlc-plugins-MacOSX-'+arch+'.h')).read_text())
    if receipt.get('sourceMaterialSHA256')!=builder.MATERIAL_SHA256 or receipt.get('sourceManifestSHA256')!=builder.MANIFEST_SHA256:raise RuntimeError('Receipt source lock mismatch')
    with tempfile.TemporaryDirectory(prefix='shelf-vlc-candidate-') as temporary:
        tmp=Path(temporary).resolve();job=builder.Build(SimpleNamespace(work=tmp,output=tmp/'evidence',arch='universal'),inputs)
        job.output.mkdir();job.owns_output=True;job.cache.mkdir();job.temporary.mkdir();(tmp/'logs').mkdir();job.materials=work/'materials'
        profile=tmp/'readonly.sb'
        protected=[PROJECT,work,package,args.materials.resolve(),args.receipt.resolve()]
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n'+''.join('(deny file-write* (subpath '+json.dumps(str(p))+'))\n' for p in protected))
        original_run=job.run
        job.run=lambda name,command,cwd,env=None,sandbox=None,timeout=7200: original_run(name,command,cwd,env=env,sandbox=sandbox or profile,timeout=timeout)
        def readonly_git(directory,*arguments):
            command=['/usr/bin/sandbox-exec','-f',str(profile),'/usr/bin/git','--no-optional-locks','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-C',str(directory),*arguments]
            result=subprocess.run(command,cwd=tmp,env=builder.clean_env(job.cache,job.temporary),capture_output=True,text=True)
            if result.returncode:raise RuntimeError('Read-only fixed source Git check failed: '+result.stderr)
            return result.stdout.strip()
        job.git=readonly_git
        verified={arch:job.verify_source(work/'jobs'/arch/'vlckit') for arch in ['arm64','x86_64']}
        actual=job.inspect('candidate',framework,dsym,['arm64','x86_64'])
        if actual['binarySHA256']!=receipt['combined']['binarySHA256']:raise RuntimeError('Actual package does not match build receipt')
        slices={};runs=[]
        capture=(PORTABLE/'direct-tail.c').read_text().replace('#include <sys/sysctl.h>','#include <sys/sysctl.h>\n#include <dlfcn.h>\n#include <limits.h>')
        anchor='    output = fopen(argv[2], "wb"); if (!output) return 3;'
        if capture.count(anchor)!=1:raise RuntimeError('Capture instrumentation anchor changed')
        capture=capture.replace(anchor,'    Dl_info loaded; char resolved[PATH_MAX];\n    if (!dladdr((void *)libvlc_get_version, &loaded) || !loaded.dli_fname || !realpath(loaded.dli_fname, resolved)) return 8;\n    printf("LOADED_PATH %s\\n", resolved);\n'+anchor)
        (tmp/'capture.c').write_text(capture)
        expected=b''.join(struct.pack('<hh',int(12000*math.sin(2*math.pi*997*n/48000)),int(12000*math.sin(2*math.pi*997*n/48000))) for n in range(96417))
        fixture=tmp/'tail.wav'
        with wave.open(str(fixture),'wb') as f:f.setnchannels(2);f.setsampwidth(2);f.setframerate(48000);f.writeframes(expected)
        for arch in ['arm64','x86_64']:
            thin=tmp/('thin-'+arch);job.run('thin-'+arch,['/usr/bin/lipo',str(binary),'-thin',arch,'-output',str(thin)],tmp,sandbox=profile)
            slices[arch]=sha(thin)
            if slices[arch]!=receipt['artifacts'][arch]['binarySHA256']:raise RuntimeError('Actual slice differs from build receipt')
            folder=tmp/arch;(folder/'bin').mkdir(parents=True);(folder/'Frameworks').mkdir();(folder/'Frameworks/VLCKit.framework').symlink_to(framework,target_is_directory=True)
            exe=folder/'bin/capture';pcm=folder/'tail.pcm';headers=work/'jobs'/arch/'vlckit/libvlc/vlc/include'
            job.run(arch+'-compile',['/usr/bin/xcrun','clang','-target',arch+'-apple-macos14.0','-I',str(headers),'-F',str(package/'macos-arm64_x86_64'),'-framework','VLCKit',str(tmp/'capture.c'),'-o',str(exe)],tmp,sandbox=profile,timeout=120)
            log=job.run(arch+'-capture',['/usr/bin/arch','-'+arch,str(exe),str(fixture),str(pcm)],tmp,sandbox=profile,timeout=45)
            values={line.split(' ',1)[0]:line.split(' ',1)[1] for line in log.splitlines() if ' ' in line}
            if Path(values.get('LOADED_PATH','')).resolve()!=binary.resolve():raise RuntimeError('Capture loaded another framework')
            if values.get('VERSION')!=builder.VERSION or values.get('CHANGESET')!=builder.CHANGESET or pcm.read_bytes()!=expected:raise RuntimeError('Actual runtime identity or 96417-frame tail mismatch')
            runs.append({'architecture':arch,'loadedPath':values['LOADED_PATH'],'version':values['VERSION'],'changeset':values['CHANGESET'],'translated':values.get('TRANSLATED')=='1','frames':96417,'byteExact':True,'pcmSHA256':sha(pcm),'captureLog':log})
        if inventory(package)!=before or args.receipt.read_bytes()!=receipt_bytes:raise RuntimeError('Inputs changed during validation')
        candidate=copy.deepcopy(seed)
        if seed['identity']!='shelf-vlc-copy-drain-input1' or seed['sourceMaterialSHA256']!=builder.MATERIAL_SHA256 or seed['runtime']!={'version':builder.VERSION,'changeset':builder.CHANGESET}:raise RuntimeError('Project fixed-source identity changed')
        candidate.update(recipeSHA256=RECIPE_SHA,packageFiles=before,binarySHA256=actual['binarySHA256'],sliceSHA256=slices,testedEnvironment=receipt['toolchain'])
        candidate['configurationPolicy']={'id':builder.POLICY_ID,'recipeSHA256':RECIPE_SHA,'expectedPluginEntries':sorted(builder.EXPECTED_PLUGIN_ENTRIES),'excludedPluginEntries':sorted(builder.EXCLUDED_PLUGIN_ENTRIES)}
        candidate['candidateReview']={'status':'GENERATED_NOT_ACTIVATED','requiresHumanSourceAndRuntimeReview':True,'receiptSHA256':hashlib.sha256(receipt_bytes).hexdigest(),'generatorSHA256':sha(Path(__file__)),'sourceFilesVerified':verified,'actualArtifact':actual,'actualRuntimeRuns':runs,'validationStages':job.stages,'limitation':'Receipt/source consistency and actual output checks are not cryptographic proof that a binary was compiled from those sources. No project lock, Vendor, or runtime expectation was changed.'}
        with output.open('x') as f:json.dump(candidate,f,indent=2);f.write('\n')
    print('CANDIDATE_ONLY '+str(output))

if __name__=='__main__':main()
