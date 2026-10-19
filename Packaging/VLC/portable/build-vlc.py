#!/usr/bin/python3 -I
"""Fixed source-only VLCKit rebuild. Default verifies/plans; --run builds offline."""
from pathlib import Path, PurePosixPath
import argparse, datetime, difflib, hashlib, io, json, math, os, platform, re
import shutil, signal, stat, struct, subprocess, sys, tarfile, time, wave

MATERIAL_SHA256 = '74c0155c93ddf1bb7312048c25a56e9693f2e86f7c68289f3a829ff0f38e489d'
MANIFEST_SHA256 = 'e7cddc8892c05f90929fe01f84ca6e166f0db53b62f278276c1e6d629115c1f3'
VLCKIT_HEAD = '319ed2c0724e3d4c4d34889a62fef1ae269491bc'
VLC_BASE = '79128878ddb2c280bbb6c89c76a46b31a80ade1c'
VLC_HEAD = '536397a641dbea2945b52fda8aa51ac5051d6b88'
CHANGESET = '3.0.23-shelf-copy-drain-input1-0-g536397a'
VERSION = '3.0.23 Vetinari'
COPY_SHA256 = 'add4be30f2840118989e5fd34c899823985823e0a08ddd01fc67c70e9e181051'
ENTRY = Path(__file__).resolve().parent

POLICY_ID = 'shelfmac-audio-abs-no-gpl-candidates-no-sftp-cast-v1'
HISTORICAL_PLUGIN_ENTRIES = frozenset(('vlc_entry__access_attachment', 'vlc_entry__access_concat', 'vlc_entry__access_dsm_libdsm', 'vlc_entry__access_ftp', 'vlc_entry__access_http', 'vlc_entry__access_http_access', 'vlc_entry__access_idummy', 'vlc_entry__access_imem_access', 'vlc_entry__access_libavio', 'vlc_entry__access_libfilesystem', 'vlc_entry__access_liblive555', 'vlc_entry__access_libnfs', 'vlc_entry__access_librist', 'vlc_entry__access_libsftp', 'vlc_entry__access_libsmb2', 'vlc_entry__access_mms_libaccess_mms', 'vlc_entry__access_output_dummy', 'vlc_entry__access_output_file', 'vlc_entry__access_output_http', 'vlc_entry__access_output_libaccess_output_rist', 'vlc_entry__access_output_libaccess_output_shout', 'vlc_entry__access_rtp_librtp', 'vlc_entry__access_satip', 'vlc_entry__access_sdp', 'vlc_entry__access_tcp', 'vlc_entry__access_timecode', 'vlc_entry__access_udp', 'vlc_entry__access_vdr', 'vlc_entry__audio_filter_channel_mixer_dolby', 'vlc_entry__audio_filter_channel_mixer_libsimple_channel_mixer', 'vlc_entry__audio_filter_channel_mixer_libspatialaudio', 'vlc_entry__audio_filter_channel_mixer_mono', 'vlc_entry__audio_filter_channel_mixer_trivial', 'vlc_entry__audio_filter_chorus_flanger', 'vlc_entry__audio_filter_compressor', 'vlc_entry__audio_filter_converter_libaudio_format', 'vlc_entry__audio_filter_converter_tospdif', 'vlc_entry__audio_filter_equalizer', 'vlc_entry__audio_filter_gain', 'vlc_entry__audio_filter_karaoke', 'vlc_entry__audio_filter_libebur128', 'vlc_entry__audio_filter_libscaletempo_pitch', 'vlc_entry__audio_filter_normvol', 'vlc_entry__audio_filter_param_eq', 'vlc_entry__audio_filter_resampler_libsoxr', 'vlc_entry__audio_filter_resampler_ugly', 'vlc_entry__audio_filter_scaletempo', 'vlc_entry__audio_filter_spatializer_spatializer', 'vlc_entry__audio_filter_stereo_widen', 'vlc_entry__audio_mixer_libfloat_mixer', 'vlc_entry__audio_mixer_libinteger_mixer', 'vlc_entry__audio_output_adummy', 'vlc_entry__audio_output_amem', 'vlc_entry__audio_output_auhal', 'vlc_entry__audio_output_libafile', 'vlc_entry__codec_adpcm', 'vlc_entry__codec_aes3', 'vlc_entry__codec_araw', 'vlc_entry__codec_audiotoolbox_midi', 'vlc_entry__codec_avcodec_libavcodec', 'vlc_entry__codec_cc', 'vlc_entry__codec_cdg', 'vlc_entry__codec_cvdsub', 'vlc_entry__codec_ddummy', 'vlc_entry__codec_dvbsub', 'vlc_entry__codec_edummy', 'vlc_entry__codec_g711', 'vlc_entry__codec_libaom', 'vlc_entry__codec_libdav1d', 'vlc_entry__codec_libflac', 'vlc_entry__codec_liblibass', 'vlc_entry__codec_libmpg123', 'vlc_entry__codec_liboggspots', 'vlc_entry__codec_libopus', 'vlc_entry__codec_libspeex', 'vlc_entry__codec_libtheora', 'vlc_entry__codec_libvideotoolbox', 'vlc_entry__codec_libvorbis', 'vlc_entry__codec_libvpx', 'vlc_entry__codec_libzvbi', 'vlc_entry__codec_lpcm', 'vlc_entry__codec_png', 'vlc_entry__codec_rawvideo', 'vlc_entry__codec_rtpvideo', 'vlc_entry__codec_scte18', 'vlc_entry__codec_scte27', 'vlc_entry__codec_spdif', 'vlc_entry__codec_spudec_libspudec', 'vlc_entry__codec_stl', 'vlc_entry__codec_subsdec', 'vlc_entry__codec_substx3g', 'vlc_entry__codec_subsusf', 'vlc_entry__codec_svcdsub', 'vlc_entry__codec_telx', 'vlc_entry__codec_textst', 'vlc_entry__codec_ttml_ttml', 'vlc_entry__codec_uleaddvaudio', 'vlc_entry__codec_webvtt_libwebvtt', 'vlc_entry__control_dummy', 'vlc_entry__demux_adaptive_libadaptive', 'vlc_entry__demux_aiff', 'vlc_entry__demux_asf_asf', 'vlc_entry__demux_au', 'vlc_entry__demux_avformat_libavformat', 'vlc_entry__demux_avi_avi', 'vlc_entry__demux_caf', 'vlc_entry__demux_demuxdump', 'vlc_entry__demux_directory', 'vlc_entry__demux_dmxmus', 'vlc_entry__demux_filter_noseek', 'vlc_entry__demux_image', 'vlc_entry__demux_libdemux_cdg', 'vlc_entry__demux_libdemux_stl', 'vlc_entry__demux_libdiracsys', 'vlc_entry__demux_libflacsys', 'vlc_entry__demux_libmod', 'vlc_entry__demux_libogg', 'vlc_entry__demux_mjpeg', 'vlc_entry__demux_mkv_libmkv', 'vlc_entry__demux_mp4_mp4', 'vlc_entry__demux_mpeg_es', 'vlc_entry__demux_mpeg_h26x', 'vlc_entry__demux_mpeg_libts', 'vlc_entry__demux_mpeg_mpgv', 'vlc_entry__demux_mpeg_ps', 'vlc_entry__demux_nsc', 'vlc_entry__demux_nsv', 'vlc_entry__demux_nuv', 'vlc_entry__demux_playlist_playlist', 'vlc_entry__demux_pva', 'vlc_entry__demux_rawaud', 'vlc_entry__demux_rawdv', 'vlc_entry__demux_rawvid', 'vlc_entry__demux_subtitle', 'vlc_entry__demux_tta', 'vlc_entry__demux_ty', 'vlc_entry__demux_vc1', 'vlc_entry__demux_vobsub', 'vlc_entry__demux_voc', 'vlc_entry__demux_wav', 'vlc_entry__demux_xa', 'vlc_entry__keystore_file', 'vlc_entry__keystore_libkeychain', 'vlc_entry__keystore_memory', 'vlc_entry__logger_syslog', 'vlc_entry__meta_engine_folder', 'vlc_entry__meta_engine_libtaglib', 'vlc_entry__misc_libsecuretransport', 'vlc_entry__misc_rtsp', 'vlc_entry__misc_xml_libxml', 'vlc_entry__mux_asf', 'vlc_entry__mux_avi', 'vlc_entry__mux_dummy', 'vlc_entry__mux_libmux_ogg', 'vlc_entry__mux_mp4_mp4', 'vlc_entry__mux_mpeg_libmux_ts', 'vlc_entry__mux_mpeg_ps', 'vlc_entry__mux_mpjpeg', 'vlc_entry__mux_wav', 'vlc_entry__packetizer_a52', 'vlc_entry__packetizer_av1', 'vlc_entry__packetizer_copy', 'vlc_entry__packetizer_dirac', 'vlc_entry__packetizer_dts', 'vlc_entry__packetizer_flac', 'vlc_entry__packetizer_h264', 'vlc_entry__packetizer_hevc', 'vlc_entry__packetizer_libpacketizer_avparser', 'vlc_entry__packetizer_mlp', 'vlc_entry__packetizer_mpeg4audio', 'vlc_entry__packetizer_mpeg4video', 'vlc_entry__packetizer_mpegaudio', 'vlc_entry__packetizer_mpegvideo', 'vlc_entry__packetizer_vc1', 'vlc_entry__services_discovery_libbonjour', 'vlc_entry__services_discovery_libupnp', 'vlc_entry__spu_logo', 'vlc_entry__spu_subsdelay', 'vlc_entry__stream_extractor_libarchive', 'vlc_entry__stream_filter_adf', 'vlc_entry__stream_filter_cache_block', 'vlc_entry__stream_filter_cache_read', 'vlc_entry__stream_filter_decomp', 'vlc_entry__stream_filter_hds_libhds', 'vlc_entry__stream_filter_inflate', 'vlc_entry__stream_filter_prefetch', 'vlc_entry__stream_filter_record', 'vlc_entry__stream_filter_skiptags', 'vlc_entry__stream_out_autodel', 'vlc_entry__stream_out_bridge', 'vlc_entry__stream_out_chromecast_libdemux_chromecast', 'vlc_entry__stream_out_chromecast_libstream_out_chromecast', 'vlc_entry__stream_out_cycle', 'vlc_entry__stream_out_delay', 'vlc_entry__stream_out_description', 'vlc_entry__stream_out_display', 'vlc_entry__stream_out_dummy', 'vlc_entry__stream_out_duplicate', 'vlc_entry__stream_out_es', 'vlc_entry__stream_out_gather', 'vlc_entry__stream_out_libstream_out_rtp', 'vlc_entry__stream_out_libstream_out_standard', 'vlc_entry__stream_out_record', 'vlc_entry__stream_out_setid', 'vlc_entry__stream_out_smem', 'vlc_entry__stream_out_transcode_libstream_out_transcode', 'vlc_entry__text_renderer_freetype_libfreetype', 'vlc_entry__text_renderer_nsspeechsynthesizer', 'vlc_entry__text_renderer_tdummy', 'vlc_entry__video_chroma_chain', 'vlc_entry__video_chroma_grey_yuv', 'vlc_entry__video_chroma_i420_rgb', 'vlc_entry__video_chroma_i422_i420', 'vlc_entry__video_chroma_libcvpx', 'vlc_entry__video_chroma_libi420_10_p010', 'vlc_entry__video_chroma_libi420_nv12', 'vlc_entry__video_chroma_libi420_yuy2', 'vlc_entry__video_chroma_libi422_yuy2', 'vlc_entry__video_chroma_libswscale', 'vlc_entry__video_chroma_rv32', 'vlc_entry__video_chroma_yuvp', 'vlc_entry__video_chroma_yuy2_i420', 'vlc_entry__video_chroma_yuy2_i422', 'vlc_entry__video_filter_adjust', 'vlc_entry__video_filter_blend', 'vlc_entry__video_filter_canvas', 'vlc_entry__video_filter_ci_filters', 'vlc_entry__video_filter_croppadd', 'vlc_entry__video_filter_deinterlace_libdeinterlace', 'vlc_entry__video_filter_edgedetection', 'vlc_entry__video_filter_fps', 'vlc_entry__video_filter_freeze', 'vlc_entry__video_filter_magnify', 'vlc_entry__video_filter_rotate', 'vlc_entry__video_filter_scale', 'vlc_entry__video_filter_transform', 'vlc_entry__video_output_caopengllayer', 'vlc_entry__video_output_flaschen', 'vlc_entry__video_output_macosx', 'vlc_entry__video_output_opengl_libglconv_cvpx', 'vlc_entry__video_output_vdummy', 'vlc_entry__video_output_vmem', 'vlc_entry__video_output_yuv'))
EXCLUDED_PLUGIN_ENTRIES = frozenset(('vlc_entry__access_libsftp', 'vlc_entry__audio_filter_channel_mixer_dolby', 'vlc_entry__audio_filter_channel_mixer_mono', 'vlc_entry__control_dummy', 'vlc_entry__logger_syslog', 'vlc_entry__misc_rtsp', 'vlc_entry__stream_out_chromecast_libdemux_chromecast', 'vlc_entry__stream_out_chromecast_libstream_out_chromecast', 'vlc_entry__stream_out_libstream_out_rtp', 'vlc_entry__video_filter_deinterlace_libdeinterlace', 'vlc_entry__video_filter_rotate'))
EXPECTED_PLUGIN_ENTRIES = HISTORICAL_PLUGIN_ENTRIES - EXCLUDED_PLUGIN_ENTRIES
if len(HISTORICAL_PLUGIN_ENTRIES)!=243 or len(EXCLUDED_PLUGIN_ENTRIES)!=11 or not EXCLUDED_PLUGIN_ENTRIES.issubset(HISTORICAL_PLUGIN_ENTRIES):
    raise RuntimeError('Unexpected fixed historical plugin policy')

def validate_plugin_header(body):
    declarations=set(re.findall(r'int (vlc_entry__\w+) ',body))
    registrations=set(re.findall(r'^\s*(vlc_entry__\w+),',body,re.M))
    if declarations!=EXPECTED_PLUGIN_ENTRIES or registrations!=EXPECTED_PLUGIN_ENTRIES:
        raise RuntimeError('Unexpected exact candidate plugin declaration/registration set')
    return declarations

def sha(path, algorithm='sha256'):
    h = hashlib.new(algorithm)
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()

def safe_name(name):
    p = PurePosixPath(name)
    if not name or p.is_absolute() or str(p) != name or any(x in ('', '.', '..') for x in p.parts):
        raise RuntimeError('Unsafe archive name: ' + name)
    return p

def safe_link(name, target):
    p = PurePosixPath(target)
    if not target or p.is_absolute(): raise RuntimeError('Unsafe symlink target')
    normalized = os.path.normpath(str(PurePosixPath(name).parent / p))
    if normalized == '..' or normalized.startswith('../'): raise RuntimeError('Escaping symlink')
    return normalized

def load_materials(path):
    if sha(path) != MATERIAL_SHA256: raise RuntimeError('SourceMaterials SHA256 mismatch; no fallback is permitted')
    with tarfile.open(path, 'r:') as tar:
        members = tar.getmembers()
        names = [m.name for m in members]
        if len(names) != len(set(names)): raise RuntimeError('Duplicate archive names')
        raw = tar.extractfile('SourceMaterialManifest.json').read()
        if hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256: raise RuntimeError('Inner manifest mismatch')
        manifest = json.loads(raw)
        expected = {r['path']: r for r in manifest['files']}
        if len(expected) != len(manifest['files']) or set(names) != set(expected) | {'SourceMaterialManifest.json'}:
            raise RuntimeError('Archive/manifest membership mismatch')
        for member in members:
            safe_name(member.name)
            if member.name == 'SourceMaterialManifest.json': continue
            row = expected[member.name]
            if 'symlink' in row:
                if not member.issym() or member.linkname != row['symlink']: raise RuntimeError('Symlink mismatch')
                safe_link(member.name, member.linkname)
            else:
                if not member.isfile() or member.size != row['bytes']: raise RuntimeError('File type/size mismatch')
                if hashlib.sha256(tar.extractfile(member).read()).hexdigest() != row['sha256']:
                    raise RuntimeError('Material content mismatch: ' + member.name)
        def data(name): return json.loads(tar.extractfile(name).read())
        lock = data('provenance/source-lock.json')
        plan = data('historical-recipes/arm64/InputPlan.json')
        work = data('historical-recipes/arm64/WorktreeResults.json')
        selected = data('historical-recipes/x86_64/ContribSelected.json') if 'historical-recipes/x86_64/ContribSelected.json' in names else None
        if selected is None: selected = data('historical-recipes/arm64/OfflineInputCheckResults.json')['architectures']['x86_64']
        packages = selected.get('actual', selected.get('selectedPackages'))
        if lock['sources'][0]['commit'] != VLCKIT_HEAD or lock['sources'][1]['commit'] != VLC_BASE:
            raise RuntimeError('Unexpected fixed source revision')
        if work['modifiedHead'] != VLC_HEAD or work['actualGitDescribeForBuild'] != CHANGESET or len(work['patches']) != 47:
            raise RuntimeError('Unexpected patch history')
        patch_names = {n for n in names if n.startswith('provenance/upstream-patches/') and n.endswith('.patch')}
        if len(patch_names) != 47: raise RuntimeError('Expected exactly 47 upstream patches')
        for patch in work['patches']:
            name = 'provenance/upstream-patches/' + patch['patch']
            if name not in patch_names or hashlib.sha256(tar.extractfile(name).read()).hexdigest() != patch['sha256']:
                raise RuntimeError('Upstream patch mismatch')
        if hashlib.sha256(tar.extractfile('provenance/copy-drain.patch').read()).hexdigest() != work['localPatchSHA256']:
            raise RuntimeError('Local patch mismatch')
        if len(plan['rows']) != 62 or len(packages) != 46: raise RuntimeError('Dependency count mismatch')
        for row in plan['rows']:
            name = 'cache/' + row['kind'] + '/' + row['filename']
            if hashlib.sha512(tar.extractfile(name).read()).hexdigest() != row['checksum']:
                raise RuntimeError('Fixed dependency archive mismatch')
        for row in lock['sources']:
            if hashlib.sha256(tar.extractfile('cache/sources/' + row['filename']).read()).hexdigest() != row['sha256']:
                raise RuntimeError('Original source archive mismatch')
    return manifest, lock, plan, work, packages

def extract_materials(archive, destination):
    destination.mkdir(mode=0o700)
    with tarfile.open(archive, 'r:') as tar:
        for member in tar:
            target = destination / str(safe_name(member.name))
            if not target.parent.resolve().is_relative_to(destination): raise RuntimeError('Parent escaped material root')
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.issym():
                safe_link(member.name, member.linkname)
                if not (target.parent / member.linkname).resolve().is_relative_to(destination): raise RuntimeError('Symlink escaped root')
                target.symlink_to(member.linkname)
            elif member.isfile():
                with target.open('xb') as f: shutil.copyfileobj(tar.extractfile(member), f)
                target.chmod(member.mode & 0o777)
            else: raise RuntimeError('Unsupported tar member type')

def clean_env(cache, temporary, developer=None):
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':os.environ['HOME'],
           'TMPDIR':str(temporary), 'XDG_CACHE_HOME':str(cache), 'GIT_CONFIG_GLOBAL':'/dev/null',
           'GIT_CONFIG_NOSYSTEM':'1', 'GIT_OPTIONAL_LOCKS':'0', 'PYTHONDONTWRITEBYTECODE':'1'}
    if developer: env['DEVELOPER_DIR'] = developer
    return env

class Build:
    def __init__(self, args, inputs):
        self.args=args; self.manifest,self.lock,self.plan,self.history,self.packages=inputs
        self.work=args.work; self.output=args.output; self.stages=[]; self.artifacts={}; self.owns_output=False
        self.cache=self.work/'cache'; self.temporary=self.work/'tmp'; self.developer=None
        self.receipt={'schemaVersion':1,'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'configurationPolicyID':POLICY_ID,'expectedPluginEntries':sorted(EXPECTED_PLUGIN_ENTRIES),'excludedPluginEntries':sorted(EXCLUDED_PLUGIN_ENTRIES),
          'sourceMaterialSHA256':MATERIAL_SHA256,'sourceManifestSHA256':MANIFEST_SHA256,'recipeSHA256':sha(Path(__file__)),
          'smokeSourceSHA256':sha(ENTRY/'direct-tail.c'),'hostArchitecture':platform.machine(),
          'work':str(self.work),'output':str(self.output),'requestedArchitecture':args.arch,'stages':self.stages,
          'noOfficialBinaryFallback':True,'formalSigningOrNotarization':False,'status':'RUNNING'}
    def save(self):
        if not self.owns_output: raise RuntimeError('Output directory is not owned by this invocation')
        (self.output/'BuildReceipt.json').write_text(json.dumps(self.receipt,indent=2)+'\n')
    def run(self, name, command, cwd, env=None, sandbox=None, timeout=7200):
        if sandbox: command=['/usr/bin/sandbox-exec','-f',str(sandbox),*command]
        log=self.work/'logs'/(name+'.log'); started=datetime.datetime.now(datetime.timezone.utc).isoformat()
        print('STAGE_START',name,flush=True)
        row={'name':name,'command':command,'cwd':str(cwd),'log':str(log),'startedUTC':started}
        self.stages.append(row); self.save()
        with log.open('wb') as f:
            process=subprocess.Popen(command,cwd=cwd,env=env or clean_env(self.cache,self.temporary,self.developer),stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            row['pid']=process.pid; self.save()
            try: code=process.wait(timeout=timeout)
            except BaseException:
                os.killpg(process.pid,signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL);process.wait()
                row.update(exit=process.returncode,interrupted=True);self.save();raise
        row.update(exit=code,finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat());self.save()
        print('STAGE_EXIT',name,code,flush=True)
        if code: raise RuntimeError(name+' failed; inspect '+str(log))
        return log.read_text(errors='replace')
    def git(self, directory, *args):
        command=['/usr/bin/git','--no-optional-locks','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-C',str(directory),*args]
        p=subprocess.run(command,cwd=self.work,env=clean_env(self.cache,self.temporary,self.developer),capture_output=True,text=True)
        if p.returncode: raise RuntimeError('Fixed source Git check failed: '+p.stderr)
        return p.stdout.strip()
    def verify_source(self, tree):
        vlc=tree/'libvlc/vlc'; hashes=json.loads((self.materials/'provenance/prepared-hashes.json').read_text())
        if sha(self.materials/'provenance/prepared-hashes.json')!=self.lock['preparedTreeManifestSHA256']: raise RuntimeError('Prepared source manifest mismatch')
        for key,row in hashes.items():
            family,relative=key.split('/',1);p=(tree if family=='vlckit' else vlc)/relative
            if 'symlink' in row:
                if not p.is_symlink() or os.readlink(p)!=row['symlink']:raise RuntimeError(key)
            elif p.is_symlink() or sha(p)!=(COPY_SHA256 if key=='vlc/modules/packetizer/copy.c' else row['sha256']) or bool(p.stat().st_mode&0o111)!=row['executable']:
                raise RuntimeError('Prepared source mismatch: '+key)
        for directory,head in [(tree,VLCKIT_HEAD),(vlc,VLC_HEAD)]:
            if (directory/'.git/objects/info/alternates').exists():raise RuntimeError('External git object store forbidden')
            if self.git(directory,'rev-parse','HEAD')!=head or self.git(directory,'diff','--name-only'):raise RuntimeError('Unexpected source HEAD/diff')
            self.git(directory,'fsck','--no-reflogs')
        if self.git(vlc,'describe','--tags','--long','--match','?.*.*','--always')!=CHANGESET or self.git(vlc,'rev-list','--count','HEAD')!='49':raise RuntimeError('Patch history identity mismatch')
        commits=self.git(vlc,'rev-list','--reverse',VLC_BASE+'..HEAD').splitlines()
        if commits!=[p['commit'] for p in self.history['patches']]+[VLC_HEAD]:raise RuntimeError('47+local commit sequence mismatch')
        return len(hashes)
    def profile(self, name, additional_readonly=()):
        p=self.work/(name+'.sb');lines=['(version 1)','(allow default)','(deny network*)']
        lines+=['(deny file-read* (subpath '+json.dumps(str(self.args.repository))+'))','(deny file-write* (subpath '+json.dumps(str(self.args.repository))+'))']
        for path in self.args.protect:
            lines+=['(deny file-read* (subpath '+json.dumps(str(path))+'))','(deny file-write* (subpath '+json.dumps(str(path))+'))']
        for path in [self.materials,ENTRY,*additional_readonly]:lines.append('(deny file-write* (subpath '+json.dumps(str(path))+'))')
        p.write_text('\n'.join(lines)+'\n');return p
    def boundary_probe(self):
        probe=self.work/'boundary-probe.py'
        probe.write_text("import errno,json,os,socket\nfrom pathlib import Path\nprotected="+repr([str(self.args.repository),*[str(p) for p in self.args.protect]])+"\nfor p in protected:\n try: os.listdir(p)\n except PermissionError: pass\n else: raise RuntimeError('protected read allowed')\ns=socket.socket();code=s.connect_ex(('127.0.0.1',9));s.close()\nif code!=errno.EPERM:raise RuntimeError('network not denied')\np=Path("+repr(str(self.materials/'SourceMaterialManifest.json'))+")\ntry:fd=os.open(p,os.O_WRONLY)\nexcept PermissionError:pass\nelse:os.close(fd);raise RuntimeError('material write allowed')\nprint('BOUNDARY_PASS network/repository/protected reads denied; material write denied')\n")
        self.run('sandbox-boundary',['/usr/bin/python3','-I',str(probe)],self.work,sandbox=self.profile('boundary'),timeout=30)
    def stage_inputs(self, tree):
        vlc=tree/'libvlc/vlc'
        for row in self.plan['rows']:
            folder=vlc/('contrib/tarballs' if row['kind']=='contrib' else 'extras/tools');folder.mkdir(parents=True,exist_ok=True)
            source=self.materials/'cache'/row['kind']/row['filename'];target=folder/row['filename']
            shutil.copy2(source,target)
            if sha(target,'sha512')!=row['checksum']:raise RuntimeError('Staged archive mismatch')
    def adapter(self, job, arch):
        code='''#!/usr/bin/python3 -I
from pathlib import Path
import os,sys
J=Path(__file__).resolve().parent;T=J/'vlckit';A=ARCH_LITERAL
args=sys.argv[1:];cwd=Path.cwd().resolve()
archive=['archive','-project','VLCKit.xcodeproj','-sdk','macosx','-configuration','Release','-scheme','VLCKit','-archivePath','build/VLCKit-macosx.xcarchive','ARCHS='+A,'IPHONEOS_DEPLOYMENT_TARGET=14.0','SKIP_INSTALL=no']
package=['-create-xcframework','-framework','VLCKit-macosx.xcarchive/Products/Library/Frameworks/VLCKit.framework','-debug-symbols',str(T/'build/VLCKit-macosx.xcarchive/dSYMs/VLCKit.framework.dSYM'),'-output','VLCKit.xcframework']
if cwd==T and args==archive:
 command=['/usr/bin/xcodebuild',*args,'MACOSX_DEPLOYMENT_TARGET=14.0','-derivedDataPath',str(J/'DerivedData'),'CLANG_MODULE_CACHE_PATH='+str(J/'ModuleCache'),'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=']
elif cwd==T/'build' and args==package:command=['/usr/bin/xcodebuild',*args]
else:raise SystemExit('PRIVATE_XCODEBUILD_REFUSED')
os.execv(command[0],command)
'''.replace('ARCH_LITERAL',repr(arch))
        p=job/'xcodebuild';p.write_text(code);p.chmod(0o755)
    def driver(self, job, tree, reuse_tools):
        original=(tree/'buildMobileVLCKit.sh').read_text();text=original
        # Candidate-only configuration policy; source provenance stays historical.
        expected_packages=[p for p in self.packages if p != 'ssh2']
        if len(self.packages)!=46 or self.packages.count('ssh2')!=1 or len(expected_packages)!=45:
            raise RuntimeError('Unexpected historical package selection')
        policy_anchor='        --enable-ad-clauses \\\n'
        policy_replacement='        --enable-ad-clauses \\\n        --disable-ssh2 \\\n'
        if text.count(policy_anchor)!=1:raise RuntimeError("Unexpected exclusion policy anchor")
        text=text.replace(policy_anchor,policy_replacement)
        policy_anchor='        --disable-addonmanagermodules \\\n'
        policy_replacement='        --disable-addonmanagermodules \\\n        --disable-sftp \\\n        --disable-chromecast \\\n'
        if text.count(policy_anchor)!=1:raise RuntimeError("Unexpected exclusion policy anchor")
        text=text.replace(policy_anchor,policy_replacement)
        policy_anchor='    spopd\n}\n\nbuildMobileKit() {'
        policy_replacement='    # ShelfMac candidate policy: exact archive basenames only, before registration.\n    [ "$OSSTYLE" = "MacOSX" ] || { echo "ShelfMac policy requires macOS" >&2; exit 1; }\n    for shelf_archive in libdeinterlace_plugin.a libdolby_surround_decoder_plugin.a libdummy_plugin.a libmono_plugin.a librotate_plugin.a libstream_out_rtp_plugin.a libsyslog_plugin.a libvod_rtsp_plugin.a libsftp_plugin.a libstream_out_chromecast_plugin.a libdemux_chromecast_plugin.a\n    do\n        find "${PREFIX}/lib/vlc/plugins" -type f -name "$shelf_archive" -exec rm \'{}\' \\;\n        [ -z "$(find "${PREFIX}/lib/vlc/plugins" -type f -name "$shelf_archive" -print -quit)" ] || exit 1\n    done\n    # Disabling the plugin alone is insufficient: upstream collects every contrib .a.\n    # Refuse stale contrib trees instead of silently deleting an unexpected dependency.\n    [ ! -e "${VLCROOT}/contrib/${OSSTYLE}${PLATFORM_IDENTIFIER}-${HOST_TRIPLET}-${ARCH}/lib/libssh2.a" ] || { echo "Unexpected libssh2 input" >&2; exit 1; }\n    [ ! -e "${PREFIX}/contribs/lib/libssh2.a" ] || { echo "Unexpected copied libssh2 input" >&2; exit 1; }\n    for shelf_archive in libstream_out_transcode_plugin.a libstream_out_smem_plugin.a libsimple_channel_mixer_plugin.a libtrivial_channel_mixer_plugin.a libaraw_plugin.a libaudio_format_plugin.a libugly_resampler_plugin.a libhttps_plugin.a libsecuretransport_plugin.a libadummy_plugin.a libidummy_plugin.a libmux_dummy_plugin.a\n    do\n        [ -f "${PREFIX}/lib/vlc/plugins/$shelf_archive" ] || { echo "Required PCM/HTTPS plugin absent: $shelf_archive" >&2; exit 1; }\n    done\n\n    spopd\n}\n\nbuildMobileKit() {'
        if text.count(policy_anchor)!=1:raise RuntimeError("Unexpected exclusion policy anchor")
        text=text.replace(policy_anchor,policy_replacement)
        if text.count('SDK_MIN=10.9')!=1:raise RuntimeError('Unexpected upstream deployment setting')
        text=text.replace('SDK_MIN=10.9','SDK_MIN=14.0')
        tool_block='''if [ "$SKIPLIBVLCCOMPILATION" != "yes" ]; then
    info "Building tools"
    spushd ${ROOT_DIR}/libvlc/vlc/extras/tools
    ./bootstrap
    make
    make .buildgas
    spopd #libvlc/vlc/extras/tools
fi'''
        if original.count(tool_block)!=1:raise RuntimeError('Unexpected upstream host tools stage')
        if reuse_tools:text=text.replace(tool_block,'# Reuse the verified host tools from this build, read-only.')
        gate=job/'check-selected.py'
        gate.write_text("from pathlib import Path\nimport json,re,subprocess\nJ=Path(__file__).resolve().parent\nexpected="+repr(expected_packages)+"\nexpected_cwd="+repr(str(tree/'libvlc/vlc/contrib'/('MacOSX-aarch64' if job.name=='arm64' else 'MacOSX-x86_64')))+"\nif str(Path.cwd().resolve())!=expected_cwd:raise RuntimeError('unexpected contrib cwd')\np=subprocess.run(['/usr/bin/make','list'],capture_output=True,text=True,check=True)\n(J/'contrib-selected.log').write_text(p.stdout+p.stderr)\nm=re.search(r'\\nTo-be-built packages:\\n(.*?)(?:\\n\\n|\\Z)',p.stdout,re.S)\nactual=m.group(1).split() if m else []\n(J/'ContribSelected.json').write_text(json.dumps({'expected':expected,'actual':actual,'passed':actual==expected},indent=2)+'\\n')\nif actual!=expected:raise RuntimeError('Candidate exact 45-component set changed; stopping before compilation')\n")
        anchor='    make fetch -j$MAKE_JOBS\n'
        if text.count(anchor)!=1:raise RuntimeError('Unexpected dependency stage')
        text=text.replace(anchor,anchor+'    /usr/bin/python3 -I '+str(gate)+'\n')
        path=tree/'portable-build.sh';path.write_text(text)
        (job/'Driver.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),text.splitlines(True),fromfile='fixed-upstream-buildMobileVLCKit.sh',tofile='portable-build.sh')))
        return path
    def inspect(self, name, framework, dsym, archs):
        binary=framework/'Versions/A/VLCKit';filetext=self.run(name+'-file',['/usr/bin/file',str(binary)],self.work)
        loads=self.run(name+'-load',['/usr/bin/otool','-l',str(binary)],self.work)
        deps=self.run(name+'-deps',['/usr/bin/otool','-L',str(binary)],self.work)
        uuid=self.run(name+'-uuid',['/usr/bin/dwarfdump','--uuid',str(binary)],self.work)
        duuid=self.run(name+'-dsym-uuid',['/usr/bin/dwarfdump','--uuid',str(dsym)],self.work)
        actual=self.run(name+'-archs',['/usr/bin/lipo','-archs',str(binary)],self.work).split()
        parse=lambda s:set(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)',s))
        if set(actual)!=set(archs) or parse(uuid)!=parse(duuid) or len(parse(uuid))!=len(archs):raise RuntimeError('Artifact architecture/dSYM mismatch')
        if len(re.findall(r'minos\s+14\.0',loads))!=len(archs):raise RuntimeError('Artifact minOS mismatch')
        for line in deps.splitlines():
            if '\t' in line:
                dependency=line.strip().split(' (')[0]
                if not dependency.startswith(('/System/Library/','/usr/lib/','@loader_path/../Frameworks/VLCKit.framework/')):raise RuntimeError('Unexpected non-system dynamic dependency '+dependency)
        return {'path':str(framework),'binarySHA256':sha(binary),'bytes':binary.stat().st_size,'architectures':actual,'UUID':uuid,'dSYMUUID':duuid,'minimumOS':'14.0'}
    def smoke(self, name, framework, tree, arch, profile):
        folder=self.work/'smoke'/name; (folder/'bin').mkdir(parents=True);(folder/'Frameworks').mkdir()
        (folder/'Frameworks/VLCKit.framework').symlink_to(framework,target_is_directory=True)
        capture=folder/'direct-tail.c';shutil.copy2(ENTRY/'direct-tail.c',capture)
        expected=b''.join(struct.pack('<hh',int(12000*math.sin(2*math.pi*997*n/48000)),int(12000*math.sin(2*math.pi*997*n/48000))) for n in range(96417))
        fixture=folder/'tail.wav'
        with wave.open(str(fixture),'wb') as f:f.setnchannels(2);f.setsampwidth(2);f.setframerate(48000);f.writeframes(expected)
        self.run(name+'-smoke-compile',['/usr/bin/xcrun','clang','-target',arch+'-apple-macos14.0','-I',str(tree/'libvlc/vlc/include'),'-F',str(folder/'Frameworks'),'-framework','VLCKit',str(capture),'-o',str(folder/'bin/capture')],folder,sandbox=profile,timeout=120)
        log=self.run(name+'-smoke-run',['/usr/bin/arch','-'+arch,str(folder/'bin/capture'),str(fixture),str(folder/'tail.pcm')],folder,sandbox=profile,timeout=40)
        pcm=(folder/'tail.pcm').read_bytes()
        actual_version=next((line[8:] for line in log.splitlines() if line.startswith('VERSION ')),None)
        actual_changeset=next((line[10:] for line in log.splitlines() if line.startswith('CHANGESET ')),None)
        if pcm!=expected or actual_version!=VERSION or actual_changeset!=CHANGESET:raise RuntimeError('Runtime identity or exact 96417-frame tail mismatch')
        return {'arch':arch,'frames':len(pcm)//4,'byteExactMatch':True,'pcmSHA256':hashlib.sha256(pcm).hexdigest(),'version':VERSION,'changeset':CHANGESET,'translated':'TRANSLATED 1' in log,'IntelHardwareClaim':False}
    def tool_snapshot(self, root):
        return {str(p.relative_to(root)):({'symlink':os.readlink(p)} if p.is_symlink() else {'sha256':sha(p),'bytes':p.stat().st_size,'mode':stat.S_IMODE(p.stat().st_mode)}) for p in root.rglob('*') if p.is_file() or p.is_symlink()}
    def build_arch(self, arch, reuse_tools=None):
        job=self.work/'jobs'/arch;job.mkdir(parents=True);tree=job/'vlckit'
        self.run(arch+'-copy-source',['/bin/cp','-cR',str(self.materials/'prepared/vlckit'),str(tree)],self.work,timeout=120)
        self.verify_source(tree)
        if any(tree.rglob('*.a')) or any(tree.rglob('*.xcframework')):raise RuntimeError('Prepared tree contains unexpected compiled library artifacts')
        self.stage_inputs(tree)
        tools_before=self.tool_snapshot(reuse_tools) if reuse_tools else None
        if reuse_tools:(tree/'libvlc/vlc/extras/tools/build').symlink_to(reuse_tools,target_is_directory=True)
        self.adapter(job,arch);self.driver(job,tree,reuse_tools)
        profile=self.profile('build-'+arch, [reuse_tools.parent.parent.parent.parent.parent] if reuse_tools else [])
        env=clean_env(self.cache,self.temporary,self.developer);env.update(MAKE_JOBS=str(self.args.jobs),VLC_PATH=str(job))
        self.run(arch+'-build',['/bin/bash','-O','xpg_echo','./portable-build.sh','-x','-n','-a','aarch64' if arch=='arm64' else arch,'-v'],tree,env=env,sandbox=profile)
        self.verify_source(tree)
        tools_after=self.tool_snapshot(reuse_tools if reuse_tools else tree/'libvlc/vlc/extras/tools/build')
        if tools_before is not None and tools_before!=tools_after:raise RuntimeError('Read-only reused host tools changed')
        (job/'HostToolsManifest.json').write_text(json.dumps({'reused':reuse_tools is not None,'files':tools_after},indent=2)+'\n')
        info=json.loads(self.run(arch+'-xcframework-info',['/usr/bin/plutil','-convert','json','-o','-',str(tree/'build/VLCKit.xcframework/Info.plist')],job))
        libs=info['AvailableLibraries']
        if len(libs)!=1 or libs[0]['SupportedArchitectures']!=[arch] or libs[0]['SupportedPlatform']!='macos':raise RuntimeError('Unexpected single-arch XCFramework')
        base=tree/'build/VLCKit.xcframework'/libs[0]['LibraryIdentifier'];framework=base/'VLCKit.framework';dsym=base/libs[0]['DebugSymbolsPath']/'VLCKit.framework.dSYM'
        validate_plugin_header((framework/'Versions/A/PrivateHeaders/vlc-plugins-MacOSX.h').read_text())
        result=self.inspect(arch,framework,dsym,[arch]);result['smoke']=self.smoke(arch,framework,tree,arch,profile)
        result.update(tree=str(tree),framework=str(framework),dsym=str(dsym),driverSHA256=sha(tree/'portable-build.sh'),adapterSHA256=sha(job/'xcodebuild'),dependencyGateSHA256=sha(job/'check-selected.py'),sandboxSHA256=sha(profile));self.artifacts[arch]=result;self.receipt['artifacts']=self.artifacts;self.save()
        return tree/'libvlc/vlc/extras/tools/build'
    def combine(self):
        import plistlib
        stage=self.work/'universal';stage.mkdir();arms=self.artifacts
        frameworks={a:Path(r['framework']) for a,r in arms.items()};dsyms={a:Path(r['dsym']) for a,r in arms.items()}
        def tree(root):return {str(p.relative_to(root)):('link',os.readlink(p)) if p.is_symlink() else ('file',sha(p)) for p in root.rglob('*') if p.is_file() or p.is_symlink()}
        at,xt=tree(frameworks['arm64']),tree(frameworks['x86_64'])
        if at.keys()!=xt.keys() or not {p for p in at if at[p]!=xt[p]}.issubset({'Versions/A/VLCKit','Versions/A/PrivateHeaders/vlc-plugins-MacOSX.h'}):raise RuntimeError('Unexpected architecture metadata difference')
        headers={a:(f/'Versions/A/PrivateHeaders/vlc-plugins-MacOSX.h').read_text() for a,f in frameworks.items()}
        entries={a:validate_plugin_header(s) for a,s in headers.items()}
        if entries['arm64']!=entries['x86_64']:raise RuntimeError('Architecture plugin policy mismatch')
        framework=stage/'VLCKit.framework';dsym=stage/'VLCKit.framework.dSYM';shutil.copytree(frameworks['arm64'],framework,symlinks=True);shutil.copytree(dsyms['arm64'],dsym,symlinks=True)
        if (dsyms['arm64']/'Contents/Info.plist').read_bytes()!=(dsyms['x86_64']/'Contents/Info.plist').read_bytes():raise RuntimeError('dSYM metadata mismatch')
        self.run('fat-binary',['/usr/bin/lipo','-create',*[str(f/'Versions/A/VLCKit') for f in frameworks.values()],'-output',str(framework/'Versions/A/VLCKit')],stage)
        self.run('fat-dsym',['/usr/bin/lipo','-create',*[str(d/'Contents/Resources/DWARF/VLCKit') for d in dsyms.values()],'-output',str(dsym/'Contents/Resources/DWARF/VLCKit')],stage)
        shutil.copytree(dsyms['x86_64']/'Contents/Resources/Relocations/x86_64',dsym/'Contents/Resources/Relocations/x86_64')
        private=framework/'Versions/A/PrivateHeaders'
        for arch,body in headers.items():(private/('vlc-plugins-MacOSX-'+arch+'.h')).write_text(body)
        (private/'vlc-plugins-MacOSX.h').write_text('#if defined(__arm64__) || defined(__aarch64__)\n#include "vlc-plugins-MacOSX-arm64.h"\n#elif defined(__x86_64__)\n#include "vlc-plugins-MacOSX-x86_64.h"\n#else\n#error Unsupported architecture\n#endif\n')
        profile=self.profile('package',[self.work/'jobs'])
        self.run('package',['/usr/bin/xcodebuild','-create-xcframework','-framework',str(framework),'-debug-symbols',str(dsym),'-output',str(self.output/'VLCKit.xcframework')],stage,sandbox=profile,timeout=300)
        info=plistlib.loads((self.output/'VLCKit.xcframework/Info.plist').read_bytes());libs=info['AvailableLibraries']
        if len(libs)!=1 or set(libs[0]['SupportedArchitectures'])!={'arm64','x86_64'}:raise RuntimeError('Unexpected combined variant')
        base=self.output/'VLCKit.xcframework'/libs[0]['LibraryIdentifier'];packed=base/'VLCKit.framework';packed_dsym=base/libs[0]['DebugSymbolsPath']/'VLCKit.framework.dSYM'
        if sha(packed_dsym/'Contents/Resources/DWARF/VLCKit')!=sha(dsym/'Contents/Resources/DWARF/VLCKit'):raise RuntimeError('Packaged dSYM bytes mismatch')
        result=self.inspect('combined',packed,packed_dsym,['arm64','x86_64']);result['smokes']=[]
        for arch in arms:
            thin=stage/('verify-'+arch)
            self.run('thin-'+arch,['/usr/bin/lipo',str(packed/'Versions/A/VLCKit'),'-thin',arch,'-output',str(thin)],stage)
            if sha(thin)!=arms[arch]['binarySHA256']:raise RuntimeError('Combined slice changed')
            result['smokes'].append(self.smoke('combined-'+arch,packed,Path(arms[arch]['tree']),arch,profile))
        self.receipt['combined']=result
    def execute(self):
        self.work.mkdir(mode=0o700);self.output.mkdir(mode=0o700);self.owns_output=True;self.cache.mkdir();self.temporary.mkdir();(self.work/'logs').mkdir();self.save()
        self.materials=self.work/'materials';extract_materials(self.args.materials,self.materials)
        self.developer=self.run('xcode-select',['/usr/bin/xcode-select','-p'],self.work).strip()
        self.receipt['toolchain']={'developerDir':self.developer,'xcode':self.run('xcode-version',['/usr/bin/xcodebuild','-version'],self.work),'sdkPath':self.run('sdk-path',['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],self.work).strip(),'sdkVersion':self.run('sdk-version',['/usr/bin/xcrun','--sdk','macosx','--show-sdk-version'],self.work).strip(),'python':sys.version,'macOS':platform.mac_ver()[0]}
        self.receipt['preparedSourceFilesVerified']=self.verify_source(self.materials/'prepared/vlckit');self.save()
        self.boundary_probe()
        targets=['arm64','x86_64'] if self.args.arch=='universal' else [self.args.arch]
        for arch in targets:self.run('runtime-availability-'+arch,['/usr/bin/arch','-'+arch,'/usr/bin/true'],self.work,timeout=30)
        reuse=None
        for arch in targets:reuse=self.build_arch(arch,reuse)
        if len(targets)==2:self.combine()
        else:
            source=Path(self.artifacts[targets[0]]['tree'])/'build/VLCKit.xcframework'
            shutil.copytree(source,self.output/'VLCKit.xcframework',symlinks=True)
            import plistlib
            info=plistlib.loads((self.output/'VLCKit.xcframework/Info.plist').read_bytes());entry=info['AvailableLibraries'][0]
            base=self.output/'VLCKit.xcframework'/entry['LibraryIdentifier'];final_framework=base/'VLCKit.framework';final_dsym=base/entry['DebugSymbolsPath']/'VLCKit.framework.dSYM'
            final=self.inspect('output-'+targets[0],final_framework,final_dsym,targets)
            if final['binarySHA256']!=self.artifacts[targets[0]]['binarySHA256']:raise RuntimeError('Copied output binary changed')
            final['smoke']=self.smoke('output-'+targets[0],final_framework,Path(self.artifacts[targets[0]]['tree']),targets[0],self.profile('output-smoke',[self.work/'jobs']))
            self.receipt['outputArtifact']=final
        self.receipt.update(status='PASS',finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat());self.save()

def checked_path(value):return Path(value).expanduser().resolve()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--materials',type=checked_path,required=True);p.add_argument('--work',type=checked_path,required=True)
    p.add_argument('--output',type=checked_path,required=True);p.add_argument('--repository',type=checked_path,required=True)
    p.add_argument('--protect',type=checked_path,action='append',default=[])
    p.add_argument('--arch',choices=['arm64','x86_64','universal'],default='universal');p.add_argument('--jobs',type=int,default=4)
    p.add_argument('--run',action='store_true');args=p.parse_args()
    if not 1<=args.jobs<=8:raise RuntimeError('jobs must be in 1..8')
    if not args.repository.is_dir():raise RuntimeError('repository must exist')
    protected=[args.repository,*args.protect,ENTRY,args.materials.parent]
    for path in [args.work,args.output]:
        if not re.fullmatch(r'/[A-Za-z0-9_./-]+',str(path)):raise RuntimeError('Fixed upstream driver requires work/output paths without whitespace or shell metacharacters')
        if path.exists():raise RuntimeError('Refusing existing work/output; inspect previous results instead of restarting')
        if any(path.is_relative_to(root) or root.is_relative_to(path) for root in protected):raise RuntimeError('Output overlaps protected/input/program path')
        if not path.parent.is_dir():raise RuntimeError('Work/output parent must already exist')
    if args.work.is_relative_to(args.output) or args.output.is_relative_to(args.work):raise RuntimeError('Work and output must be separate')
    inputs=load_materials(args.materials)
    print('MATERIALS_PASS',len(inputs[0]['files']),'entries; 62 SHA512 archives; 47 upstream + local patch; fixed source lock',flush=True)
    if not args.run:
        print('CHECK_ONLY',json.dumps({'work':str(args.work),'output':str(args.output),'arch':args.arch,'repositoryDenied':str(args.repository),'protectedReadWriteDenied':[str(x) for x in args.protect],'requiresRuntimeSmoke':True}));return
    build=Build(args,inputs)
    try:build.execute()
    except BaseException as error:
        build.receipt.update(status='FAILED',failure=str(error),finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        if build.owns_output:build.save()
        raise
    print('PORTABLE_BUILD_PASS',str(args.output/'BuildReceipt.json'),flush=True)
if __name__=='__main__':main()
