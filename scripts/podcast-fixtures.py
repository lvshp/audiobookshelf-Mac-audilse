#!/usr/bin/env python3
"""Disposable loopback-only RSS/ABS podcast fixtures for native UI acceptance.

prepare: start RSS, create its dedicated library/show, download episodes 1 and 2.
status: safely show public fixture identifiers. stop: stop only this RSS process.
cleanup: delete only the validated fixture podcast library, then stop RSS.
ABS 2.37.1 must use SSRF_REQUEST_FILTER_WHITELIST=127.0.0.1 for this local feed.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from xml.sax.saxutils import escape
import argparse
import json
import os
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib

ROOT = Path('/private/tmp/shelf-podcast-fixtures')
ABS_ROOT = Path('/private/tmp/shelf-compat-servers/v2.37.1')
ABS_BASE = 'http://127.0.0.1:13371/compat'
RSS_BASE = 'http://127.0.0.1:13373/podcast-fixture/v1'
LIBRARY_NAME = 'Audilse Podcast Fixtures'
SHOW_TITLE = 'Audilse Podcast Demo'
IDENTITY = 'AudilsePodcastFixturesV1'
EPISODE_TITLES = [
    'Fixture Episode 01 - First Chapter',
    'Fixture Episode 02 - Returning Home',
    'Fixture Episode 03 - Queue Test',
    'Fixture Episode 04 - RSS Match Test',
    'Fixture Episode 05 - Slow Download',
    'Fixture Episode 06 - Latest Episode',
]
os.umask(0o077)


class FixtureNeedsReset(Exception):
    pass


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())


def save(path, value):
    temporary = path.with_suffix('.temporary')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.chmod(0o600)
    temporary.replace(path)


def request(url, method='GET', body=None, token=None):
    parsed = urlsplit(url)
    assert parsed.scheme == 'http' and parsed.hostname == '127.0.0.1' and parsed.username is None
    assert (parsed.port == 13371 and parsed.path.startswith('/compat/')) or (parsed.port == 13373 and parsed.path.startswith('/podcast-fixture/v1/'))
    headers = {'Accept': 'application/json', 'x-return-tokens': 'true'}
    if token:
        assert parsed.port == 13371
        headers['Authorization'] = 'Bearer ' + token
    payload = None if body is None else json.dumps(body).encode()
    if payload is not None:
        headers['Content-Type'] = 'application/json'
    with OPENER.open(urllib.request.Request(url, data=payload, headers=headers, method=method), timeout=20) as response:
        data = response.read()
        try:
            return json.loads(data)
        except ValueError:
            return None


def login():
    auth_file = ABS_ROOT / 'auth.json'
    values = auth_file.lstat()
    assert stat.S_ISREG(values.st_mode) and stat.S_IMODE(values.st_mode) == 0o600
    auth = json.loads(auth_file.read_text())
    assert auth['version'] == '2.37.1' and auth['baseURL'] == ABS_BASE
    assert request(ABS_BASE + '/status')['serverVersion'] == '2.37.1'
    user = request(ABS_BASE + '/login', 'POST', {'username': auth['username'], 'password': auth['password']})['user']
    assert user['id'] == auth['userID'] and user['type'] == 'root'
    return user.get('accessToken') or user['token']


def cover():
    width = height = 320
    rows = b''.join(b'\0' + bytes((75, 99, 195)) * width for _ in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def feed():
    size = (ROOT / 'audio.mp3').stat().st_size
    items = []
    for number in range(6, 0, -1):
        title = EPISODE_TITLES[number - 1]
        items.append(f'''<item><title>{escape(title)}</title><guid isPermaLink="false">urn:audilse:podcast-fixture:episode:{number:02}</guid>
<description><![CDATA[<p>Synthetic forty-second episode {number}. Safe fixture for editing and RSS matching.</p>]]></description>
<itunes:subtitle>Audilse local acceptance episode {number}</itunes:subtitle><itunes:author>Audilse Fixture Lab</itunes:author>
<pubDate>Mon, 12 Oct 2026 {number:02}:00:00 +0000</pubDate><itunes:duration>00:00:40</itunes:duration>
<itunes:episode>{number}</itunes:episode><itunes:season>1</itunes:season><itunes:episodeType>full</itunes:episodeType><itunes:explicit>no</itunes:explicit>
<enclosure url="{RSS_BASE}/audio/episode-{number:02}.mp3" length="{size}" type="audio/mpeg"/></item>''')
    return (f'''<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom"><channel>
<title>{SHOW_TITLE}</title><link>{RSS_BASE}/feed.xml</link><language>en</language>
<description>Six synthetic forty-second episodes for Audilse native podcast acceptance.</description>
<atom:link href="{RSS_BASE}/feed.xml" rel="self" type="application/rss+xml"/>
<itunes:author>Audilse Fixture Lab</itunes:author><itunes:explicit>no</itunes:explicit><itunes:type>episodic</itunes:type>
<itunes:category text="Technology"/><itunes:image href="{RSS_BASE}/cover.png"/>
{''.join(items)}</channel></rss>''').encode()


class RSSHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Never log headers, request bodies or credentials.

    def do_HEAD(self):
        self.respond(head_only=True)

    def do_GET(self):
        self.respond(head_only=False)

    def respond(self, head_only):
        path = urlsplit(self.path).path
        base = '/podcast-fixture/v1/'
        if self.headers.get('Host') != '127.0.0.1:13373':
            self.send_error(400)
            return
        if path == base + 'health':
            data = json.dumps({'fixture': IDENTITY, 'pid': os.getpid()}).encode()
            content_type = 'application/json'
            slow = False
        elif path == base + 'feed.xml':
            data = feed()
            content_type = 'application/rss+xml; charset=utf-8'
            slow = False
        elif path == base + 'cover.png':
            data = cover()
            content_type = 'image/png'
            slow = False
        elif path in {base + f'audio/episode-{number:02}.mp3' for number in range(1, 7)}:
            data = (ROOT / 'audio.mp3').read_bytes()
            content_type = 'audio/mpeg'
            slow = int(path[-6:-4]) >= 3
        else:
            self.send_error(404)
            return
        start, end, status = 0, len(data) - 1, 200
        byte_range = self.headers.get('Range')
        if byte_range:
            try:
                assert len(byte_range) < 128 and byte_range.startswith('bytes=') and ',' not in byte_range
                left, right = byte_range[6:].split('-')
                if left:
                    start = int(left)
                    end = min(end, int(right)) if right else end
                else:
                    start = max(0, len(data) - int(right))
                assert 0 <= start <= end < len(data)
                status = 206
            except (ValueError, AssertionError):
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(data)}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Cache-Control', 'no-store')
        if status == 206:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if head_only:
            return
        chunk_size = 4096 if slow else 65536
        try:
            for offset in range(start, end + 1, chunk_size):
                self.wfile.write(data[offset:min(offset + chunk_size, end + 1)])
                self.wfile.flush()
                if slow:
                    time.sleep(0.25)  # Remaining episodes expose a visible server queue.
        except (BrokenPipeError, ConnectionResetError):
            pass


def start_rss():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    source_directory = ABS_ROOT / 'media/Compat Author/Compat Series/1 - Compat Sample'
    source = next(source_directory.glob('*.mp3'))
    assert source.resolve().is_relative_to((ABS_ROOT / 'media').resolve())
    shutil.copyfile(source, ROOT / 'audio.mp3')
    try:
        existing = request(RSS_BASE + '/health')
        assert existing['fixture'] == IDENTITY
        assert int((ROOT / 'rss.pid').read_text()) == existing['pid']
        return
    except urllib.error.URLError:
        pass
    with (ROOT / 'rss.log').open('ab') as log:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'serve'], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    (ROOT / 'rss.pid').write_text(str(process.pid))
    for _ in range(60):
        try:
            health = request(RSS_BASE + '/health')
            assert health['fixture'] == IDENTITY and health['pid'] == process.pid
            return
        except urllib.error.URLError:
            if process.poll() is not None:
                raise RuntimeError('Local RSS failed to start')
            time.sleep(0.1)
    raise RuntimeError('Local RSS startup timeout')


def prepare():
    start_rss()
    token = login()
    directory = ROOT / 'library'
    directory.mkdir(exist_ok=True)
    libraries = request(ABS_BASE + '/api/libraries', token=token)['libraries']
    library = next((value for value in libraries if value['name'] == LIBRARY_NAME), None)
    if library is None:
        library = request(ABS_BASE + '/api/libraries', 'POST', {'name': LIBRARY_NAME, 'mediaType': 'podcast', 'provider': 'itunes', 'folders': [{'fullPath': str(directory)}], 'settings': {'disableWatcher': True}}, token)
    else:
        library = request(ABS_BASE + '/api/libraries/' + library['id'], token=token)
    assert library['name'] == LIBRARY_NAME and library['mediaType'] == 'podcast'
    assert len(library['folders']) == 1 and Path(library['folders'][0]['fullPath']).resolve() == directory.resolve()
    folder_id = library['folders'][0]['id']
    parsed = request(ABS_BASE + '/api/podcasts/feed', 'POST', {'rssFeed': RSS_BASE + '/feed.xml'}, token)['podcast']
    assert parsed['metadata']['title'] == SHOW_TITLE and len(parsed['episodes']) == 6
    assert parsed['metadata']['feedUrl'] == RSS_BASE + '/feed.xml'
    assert all(episode['enclosure']['url'].startswith(RSS_BASE + '/audio/') for episode in parsed['episodes'])
    print('PASS official ABS RSS parsing: six synthetic episodes')
    items = request(ABS_BASE + '/api/libraries/' + library['id'] + '/items?minified=0&limit=100', token=token)['results']
    show_path = directory / SHOW_TITLE
    show = next((item for item in items if Path(item.get('path', '')).resolve() == show_path.resolve()), None)
    if show is None:
        metadata = dict(parsed['metadata'])
        metadata.update({'genres': metadata.pop('categories', []), 'explicit': False, 'imageUrl': metadata.get('image')})
        show = request(ABS_BASE + '/api/podcasts', 'POST', {'libraryId': library['id'], 'folderId': folder_id, 'path': str(show_path), 'media': {'metadata': metadata, 'autoDownloadEpisodes': False}}, token)
    show = request(ABS_BASE + '/api/items/' + show['id'] + '?expanded=1', token=token)
    assert show['libraryId'] == library['id'] and show['media']['metadata']['title'] == SHOW_TITLE and show['media']['metadata']['feedUrl'] == RSS_BASE + '/feed.xml'
    existing_guids = {episode.get('guid') for episode in show['media'].get('episodes', [])}
    expected_guids = {f'urn:audilse:podcast-fixture:episode:{number:02}' for number in (1, 2)}
    queue = request(ABS_BASE + '/api/libraries/' + library['id'] + '/episode-downloads', token=token)
    active = queue.get('queue', []) + ([queue['currentDownload']] if queue.get('currentDownload') else [])
    if not existing_guids.issubset(expected_guids) or any(download.get('libraryItemId') == show['id'] for download in active):
        raise FixtureNeedsReset()
    selected = [episode for episode in parsed['episodes'] if episode.get('episode') in ('1', '2') and episode.get('guid') not in existing_guids]
    if selected:
        request(ABS_BASE + '/api/podcasts/' + show['id'] + '/download-episodes', 'POST', selected, token)
    for _ in range(100):
        show = request(ABS_BASE + '/api/items/' + show['id'] + '?expanded=1', token=token)
        episodes = show['media'].get('episodes', [])
        found = [episode for episode in episodes if episode.get('guid') in expected_guids]
        queue = request(ABS_BASE + '/api/libraries/' + library['id'] + '/episode-downloads', token=token)
        active = queue.get('queue', []) + ([queue['currentDownload']] if queue.get('currentDownload') else [])
        if len(episodes) == len(found) == 2 and all(abs(episode.get('audioFile', {}).get('duration', 0) - 40) < 1 for episode in found) and not any(download.get('libraryItemId') == show['id'] for download in active):
            break
        time.sleep(0.2)
    else:
        raise RuntimeError('Server episode download timeout')
    print('PASS server downloads: episodes 01/02, each actual duration >35 seconds')
    recent = request(ABS_BASE + '/api/libraries/' + library['id'] + '/recent-episodes?limit=50&page=0', token=token)
    assert expected_guids.issubset({episode.get('guid') for episode in recent['episodes']})
    matched = request(ABS_BASE + '/api/podcasts/' + show['id'] + '/search-episode?title=Fixture%20Episode%2001%20-%20First%20Chapter', token=token)
    assert any(match['episode'].get('guid') == 'urn:audilse:podcast-fixture:episode:01' for match in matched['episodes'])
    print('PASS latest episodes and RSS matching release routes')
    save(ROOT / 'manifest.json', {'fixture': IDENTITY, 'server': ABS_BASE, 'rssURL': RSS_BASE + '/feed.xml', 'libraryID': library['id'], 'libraryName': LIBRARY_NAME, 'folderID': folder_id, 'folderPath': str(directory), 'itemID': show['id'], 'showTitle': SHOW_TITLE, 'initialEpisodes': [{'id': episode['id'], 'title': episode['title']} for episode in found]})
    status(token)


def status(token=None):
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    assert manifest['fixture'] == IDENTITY and manifest['server'] == ABS_BASE
    token = token or login()
    show = request(ABS_BASE + '/api/items/' + manifest['itemID'] + '?expanded=1', token=token)
    assert show['libraryId'] == manifest['libraryID'] and show['mediaType'] == 'podcast'
    episodes = show['media'].get('episodes', [])
    guids = {episode.get('guid') for episode in episodes}
    remaining = [number for number in range(1, 7) if f'urn:audilse:podcast-fixture:episode:{number:02}' not in guids]
    queue = request(ABS_BASE + '/api/libraries/' + manifest['libraryID'] + '/episode-downloads', token=token)
    active = queue.get('queue', []) + ([queue['currentDownload']] if queue.get('currentDownload') else [])
    print('LIBRARY', manifest['libraryName'])
    print('SHOW', manifest['showTitle'])
    print('RSS', manifest['rssURL'])
    print('FOLDER', manifest['folderPath'])
    print('ACTUAL DOWNLOADED EPISODES', len(episodes))
    print('ACTUAL REMAINING', ', '.join(f'{number:02}' for number in remaining) or 'none')
    print('ACTUAL ACTIVE DOWNLOADS', sum(download.get('libraryItemId') == show['id'] for download in active))
    print('QUEUE FIXTURE', 'Episodes 03-06 download at approximately 16 KiB/s')


def stop_rss():
    try:
        health = request(RSS_BASE + '/health')
    except urllib.error.URLError:
        print('RSS already stopped')
        return
    pid = int((ROOT / 'rss.pid').read_text())
    assert health['fixture'] == IDENTITY and health['pid'] == pid
    command = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'command='], text=True)
    assert str(Path(__file__).resolve()) + ' serve' in command
    os.kill(pid, signal.SIGTERM)
    print('Stopped only fixture RSS process')


def cleanup():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    assert manifest['fixture'] == IDENTITY and manifest['server'] == ABS_BASE
    token = login()
    library = request(ABS_BASE + '/api/libraries/' + manifest['libraryID'], token=token)
    assert library['name'] == LIBRARY_NAME and library['mediaType'] == 'podcast'
    assert len(library['folders']) == 1 and Path(library['folders'][0]['fullPath']).resolve() == (ROOT / 'library').resolve()
    request(ABS_BASE + '/api/libraries/' + library['id'], 'DELETE', token=token)
    stop_rss()
    print('Removed only podcast fixture library; synthetic files retained at', ROOT)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'serve', 'status', 'stop', 'cleanup'])
    args = parser.parse_args()
    try:
        if args.command == 'serve':
            server = ThreadingHTTPServer(('127.0.0.1', 13373), RSSHandler)
            server.daemon_threads = True
            server.serve_forever()
        else:
            {'prepare': prepare, 'status': status, 'stop': stop_rss, 'cleanup': cleanup}[args.command]()
    except urllib.error.HTTPError as error:
        raise SystemExit('Fixture HTTP ' + str(error.code)) from None
    except FixtureNeedsReset:
        raise SystemExit('Podcast fixture changed; run cleanup before preparing a fresh acceptance state.') from None
    except Exception as error:
        # Never print arbitrary HTTP bodies, request objects or credential values.
        raise SystemExit('Podcast fixture failed: ' + type(error).__name__) from None
