#!/usr/bin/python3
"""Adversarial loopback-only share fixture; no production state or credentials."""
import argparse,datetime,email.utils,hashlib,http.server,json,threading,time,urllib.parse,uuid
DATA=bytes(range(256))*256
LOCK=threading.Lock()
STATE={'sessions':{},'records':[],'failProgress':False,'generation':0,'bytesSent':{},'downloadAllowed':True}
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def body(self,status,data=b'',headers=None):
        self.send_response(status)
        for key,value in (headers or {}).items():self.send_header(key,value)
        self.send_header('Content-Length',str(len(data)));self.end_headers()
        if data:
            try:self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError):pass
    def record(self):
        cookie=self.headers.get('Cookie','');names=[p.strip().split('=',1)[0] for p in cookie.split(';') if p.strip()]
        with LOCK:STATE['records'].append({'method':self.command,'path':self.path,'cookieNames':names,'cookieDigest':hashlib.sha256(cookie.encode()).hexdigest(),'authorization':bool(self.headers.get('Authorization')),'proxyAuthorization':bool(self.headers.get('Proxy-Authorization'))})
        return dict(p.strip().split('=',1) for p in cookie.split(';') if '=' in p).get('share_session_id')
    def control(self):
        if self.path!='/__control':return False
        if self.command=='POST':
            payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            with LOCK:
                if payload.pop('restart',False):STATE['sessions'].clear();STATE['generation']+=1
                if payload.pop('clearRecords',False):STATE['records']=[]
                STATE.update(payload)
        with LOCK:data=json.dumps({k:v for k,v in STATE.items() if k!='sessions'}).encode()
        self.body(200,data,{'Content-Type':'application/json'});return True
    def do_POST(self):
        if not self.control():self.body(404)
    def do_GET(self):
        if self.control():return
        cookie=self.record();parsed=urllib.parse.urlsplit(self.path);parts=parsed.path.split('/')
        if len(parts)<5 or parts[1:4]!=['prefix','public','share']:self.body(404);return
        slug=urllib.parse.unquote(parts[4]);suffix=parts[5:]
        if slug=='gone':self.body(404,b'Not Found');return
        if not suffix:
            if slug=='slow-open':time.sleep(.5)
            if slug=='redirect':self.body(302,headers={'Location':'/__sink'});return
            with LOCK:
                current=STATE['sessions'].get(cookie)
                if not current or current['slug']!=slug:
                    cookie=str(uuid.uuid4());current={'id':str(uuid.uuid4()),'slug':slug,'time':0};STATE['sessions'][cookie]=current
                initial=urllib.parse.parse_qs(parsed.query).get('t')
                if initial:current['time']=min(float(initial[0]),4)
                allowed=STATE['downloadAllowed'];position=current['time'];session_id=current['id']
            doc={'id':'share-'+slug,'mediaItemId':'book-'+slug,'mediaItemType':'book','slug':slug,'expiresAt':STATE.get('expiresAt'),'isDownloadable':allowed,'playbackSession':{'id':session_id,'displayTitle':'Public synthetic book','displayAuthor':'Fixture','duration':4,'currentTime':position,'coverPath':'/fixture/cover.jpg','serverVersion':'2.37.1','chapters':[{'id':0,'title':'One','start':0,'end':4}],'audioTracks':[{'index':i,'title':'track '+str(i),'startOffset':(i-1)*2,'duration':2,'contentUrl':'/prefix/public/share/'+urllib.parse.quote(slug,safe='')+'/track/'+str(i),'mimeType':'audio/wav'} for i in [1,2]]}}
            if slug=='cross-origin':doc['playbackSession']['audioTracks'][0]['contentUrl']='http://127.0.0.1:1/prefix/public/share/cross-origin/track/1'
            if slug=='bad-cookie':cookie='not-a-valid-session'
            expiry=email.utils.formatdate(time.time()+30*86400,usegmt=True)
            self.body(200,json.dumps(doc).encode(),{'Content-Type':'application/json','Set-Cookie':'share_session_id='+cookie+'; Path=/; HttpOnly; Expires='+expiry});return
        with LOCK:current=STATE['sessions'].get(cookie)
        if not current or current['slug']!=slug:self.body(404,b'Share session not found');return
        if suffix==['cover']:
            if slug=='huge-cover':self.stream(200,16*1024*1024,{'Content-Type':'image/jpeg'},slug);return
            self.body(200,b'\xff\xd8fixture\xff\xd9',{'Content-Type':'image/jpeg'});return
        if suffix==['download']:
            with LOCK:allowed=STATE['downloadAllowed']
            if not allowed:self.body(403,b'Download is not allowed for this item');return
            if slug=='slow-download':self.stream(200,32*1024*1024,{},slug,slow=True);return
            self.body(200,b'PK\x03\x04'+DATA,{'Content-Type':'application/zip','Content-Disposition':'attachment; filename="../share.zip"'});return
        if len(suffix)==2 and suffix[0]=='track':
            if slug=='track-redirect':self.body(302,headers={'Location':'/__sink'});return
            raw=self.headers.get('Range','')
            try:start,end=map(int,raw.removeprefix('bytes=').split('-'))
            except ValueError:self.body(400);return
            if start>=len(DATA):self.body(416,headers={'Content-Range':'bytes */'+str(len(DATA))});return
            end=min(end,len(DATA)-1)
            if slug=='ignore-range':self.stream(200,32*1024*1024,{},slug);return
            if slug=='oversized-range':self.stream(206,32*1024*1024,{'Content-Range':f'bytes {start}-{end}/{len(DATA)}'},slug);return
            if slug=='wrong-range':start+=1
            if slug=='chunk-overflow':
                self.send_response(206);self.send_header('Content-Type','audio/wav');self.send_header('Content-Range',f'bytes {start}-{end}/{len(DATA)}');self.send_header('Transfer-Encoding','chunked');self.end_headers()
                data=b'x'*(end-start+2)
                try:self.wfile.write(f'{len(data):X}\r\n'.encode()+data+b'\r\n0\r\n\r\n')
                except (BrokenPipeError,ConnectionResetError):pass
                return
            self.body(206,DATA[start:end+1],{'Content-Type':'audio/wav','Content-Range':f'bytes {start}-{end}/{len(DATA)}'});return
        self.body(404)
    def stream(self,status,size,headers,slug,slow=False):
        self.send_response(status)
        for key,value in headers.items():self.send_header(key,value)
        self.send_header('Content-Length',str(size));self.end_headers();sent=0
        try:
            while sent<size:
                chunk=b'x'*min(32768,size-sent);self.wfile.write(chunk);self.wfile.flush();sent+=len(chunk)
                if slow:time.sleep(.02)
        except (BrokenPipeError,ConnectionResetError):pass
        with LOCK:STATE['bytesSent'][slug]=sent
    def do_PATCH(self):
        cookie=self.record();parts=urllib.parse.urlsplit(self.path).path.split('/');payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        if len(parts)!=6 or parts[1:4]!=['prefix','public','share'] or parts[5]!='progress':self.body(404);return
        with LOCK:
            current=STATE['sessions'].get(cookie);failed=STATE['failProgress']
            if current and current['slug']!=urllib.parse.unquote(parts[4]):current=None
            if current and not failed:current['time']=min(payload['currentTime'],4)
        if failed:self.body(503,b'temporary fixture failure')
        elif not current:self.body(404,b'Share session not found')
        else:self.body(204)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--info',required=True);args=parser.parse_args()
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);host,port=server.server_address
    with open(args.info,'x') as output:json.dump({'origin':f'http://{host}:{port}','baseURL':f'http://{host}:{port}/prefix'},output)
    print('Synthetic public-share loopback ready',flush=True);server.serve_forever()
