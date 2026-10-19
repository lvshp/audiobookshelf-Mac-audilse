#!/usr/bin/env python3
"""Create brand-new disposable official ABS loopback instances and synthetic public shares.
Requires local fixed source/dependencies, Node, ffmpeg/ffprobe. No existing config or credentials.
"""
import argparse,json,os,secrets,socket,subprocess,time,urllib.request,wave,struct,math
from pathlib import Path
os.umask(0o077)
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--source-root',type=Path,default=Path('/private/tmp'));p.add_argument('--node',required=True);a=p.parse_args()
    a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    manifest=[]
    for version in ['2.26.0','2.37.1']:
        folder=a.output/version;folder.mkdir();media=folder/'media'/'Synthetic Author'/'Public Book';media.mkdir(parents=True)
        for index in [1,2]:
            with wave.open(str(media/f'{index:02}.wav'),'wb') as w:
                w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000)
                w.writeframes(b''.join(struct.pack('<h',int(8000*math.sin(i*.1))) for i in range(32000)))
        # Generated 1x1 PNG, no downloaded/user media.
        import base64
        (media/'cover.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6L1sAAAAASUVORK5CYII='))
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        assert port!=53429
        source=a.source_root/('audiobookshelf-'+version)
        assert json.loads((source/'package.json').read_text())['version']==version
        env=os.environ.copy();env.update(NODE_ENV='production',HOST='127.0.0.1',PORT=str(port),CONFIG_PATH=str(folder/'config'),METADATA_PATH=str(folder/'metadata'),ROUTER_BASE_PATH='/anonymous-test',SKIP_BINARIES_CHECK='1',FFMPEG_PATH='/opt/homebrew/bin/ffmpeg',FFPROBE_PATH='/opt/homebrew/bin/ffprobe')
        entry='dist-server/index.js' if version=='2.37.1' else 'index.js'
        with (folder/'server.log').open('wb') as log:process=subprocess.Popen([a.node,entry],cwd=source,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
        (folder/'pid').write_text(str(process.pid));base=f'http://127.0.0.1:{port}/anonymous-test';token=None
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs):return None
        opener=urllib.request.build_opener(NoRedirect())
        def req(path,method='GET',body=None):
            headers={'Content-Type':'application/json','x-return-tokens':'true'}
            if token:headers['Authorization']='Bearer '+token
            with opener.open(urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method),timeout=10) as r:
                data=r.read()
                try:return json.loads(data) if data else None
                except ValueError:return None
        for _ in range(100):
            try:status=req('/status');break
            except Exception:
                if process.poll() is not None:raise RuntimeError('new fixture server exited')
                time.sleep(.2)
        else:raise RuntimeError('new fixture startup timeout')
        assert status['serverVersion']==version and not status['isInit']
        password=secrets.token_urlsafe(32);username='isolated-public-fixture'
        req('/init','POST',{'newRoot':{'username':username,'password':password}})
        user=req('/login','POST',{'username':username,'password':password})['user'];token=user.get('accessToken') or user.get('token');assert token
        library=req('/api/libraries','POST',{'name':'Anonymous Synthetic Fixture','mediaType':'book','provider':'google','folders':[{'fullPath':str(folder/'media')}],'settings':{'disableWatcher':True}})
        req('/api/libraries/'+library['id']+'/scan','POST')
        for _ in range(100):
            items=req('/api/libraries/'+library['id']+'/items?minified=0')['results']
            if items:
                item=req('/api/items/'+items[0]['id']+'?expanded=1')
                if len(item['media'].get('tracks',[]))==2:break
            time.sleep(.2)
        else:raise RuntimeError('synthetic scan timeout')
        share=req('/api/share/mediaitem','POST',{'slug':'synthetic-public','mediaItemId':item['media']['id'],'mediaItemType':'book','expiresAt':0,'isDownloadable':True})
        # Only disposable fixture password retained, mode0600; never passed to native client.
        (folder/'fixture-admin.json').write_text(json.dumps({'username':username,'password':password,'baseURL':base,'shareID':share['id']}))
        manifest.append({'version':version,'baseURL':base,'link':base+'/share/synthetic-public','pid':process.pid,'folder':str(folder),'trackFiles':[str(media/f'{i:02}.wav') for i in [1,2]]})
        print('READY',version,'new loopback port',port,flush=True)
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
if __name__=='__main__':main()
