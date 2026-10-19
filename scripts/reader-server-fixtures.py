#!/usr/bin/env python3
"""Seed only the disposable 2.37.1 loopback fixture server; never print credentials."""
from pathlib import Path
import argparse
import importlib.util
import json
import os
import shutil
import stat
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path('/private/tmp/shelf-compat-servers/v2.37.1')
BASE = 'http://127.0.0.1:13371/compat'
os.umask(0o077)


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def seed(output):
    auth_file = ROOT / 'auth.json'
    auth_stat = auth_file.lstat()
    assert stat.S_ISREG(auth_stat.st_mode) and stat.S_IMODE(auth_stat.st_mode) == 0o600
    auth = json.loads(auth_file.read_text())
    assert auth['version'] == '2.37.1' and auth['baseURL'] == BASE
    opener = urllib.request.build_opener(NoRedirects())
    token = None

    def request(route, method='GET', body=None):
        headers = {'Accept': 'application/json', 'x-return-tokens': 'true'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        payload = None if body is None else json.dumps(body).encode()
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        with opener.open(urllib.request.Request(BASE + route, data=payload, headers=headers, method=method), timeout=20) as response:
            result = response.read()
            try:
                return json.loads(result)
            except ValueError:
                return None

    assert request('/status')['serverVersion'] == '2.37.1'
    user = request('/login', 'POST', {'username': auth['username'], 'password': auth['password']})['user']
    assert user['id'] == auth['userID'] and user['type'] == 'root'
    token = user.get('accessToken') or user.get('token')
    library = request('/api/libraries/' + auth['libraryID'])
    assert library['name'] == 'Audilse Compatibility Fixtures'
    assert len(library['folders']) == 1 and Path(library['folders'][0]['fullPath']).resolve() == (ROOT / 'media').resolve()
    generator_path = Path(__file__).with_name('reader-fixtures.py')
    spec = importlib.util.spec_from_file_location('reader_fixtures', generator_path)
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    generated = output / 'generated'
    generator.generate(generated)
    audio = ROOT / 'media/Compat Author/Compat Series/1 - Compat Sample/fixture.mp3'
    if not audio.is_file():
        audio = next((ROOT / 'media/Compat Author/Compat Series/1 - Compat Sample').glob('*.mp3'))
    formats = ['pdf', 'cbz', 'cbr', 'azw3', 'mobi', 'epub']
    for fmt in formats:
        folder = ROOT / 'media/Reader Fixtures' / ('Audilse Reading ' + fmt.upper())
        folder.mkdir(parents=True, exist_ok=True)
        assert folder.resolve().is_relative_to((ROOT / 'media/Reader Fixtures').resolve())
        shutil.copyfile(audio, folder / 'synthetic-audio.mp3')
        shutil.copyfile(generated / ('fixture.' + fmt), folder / ('Audilse Reading ' + fmt.upper() + '.' + fmt))
    request('/api/libraries/' + auth['libraryID'] + '/scan', 'POST')
    found = {}
    for _ in range(60):
        items = request('/api/libraries/' + auth['libraryID'] + '/items?minified=0&limit=100&page=0')['results']
        for item in items:
            path = Path(item.get('path', '')).resolve()
            for fmt in formats:
                expected = ROOT / 'media/Reader Fixtures' / ('Audilse Reading ' + fmt.upper())
                if path == expected.resolve():
                    expanded = request('/api/items/' + item['id'] + '?expanded=1')
                    ebook = expanded.get('media', {}).get('ebookFile')
                    expected_bytes = (generated / ('fixture.' + fmt)).stat().st_size
                    if ebook and Path(ebook['metadata']['filename']).suffix.lower() == '.' + fmt and ebook['metadata'].get('size') == expected_bytes:
                        found[fmt] = expanded
                    else:
                        found.pop(fmt, None)
        if len(found) == len(formats):
            break
        time.sleep(0.25)
    assert set(found) == set(formats), 'Reader fixture scan did not find all formats'
    for fmt, item in found.items():
        title = 'Audilse Reading ' + fmt.upper()
        request('/api/items/' + item['id'] + '/media', 'PATCH', {'metadata': {'title': title}})
        found[fmt] = request('/api/items/' + item['id'] + '?expanded=1')
        assert found[fmt]['media']['metadata']['title'] == title
    # No credential enters this manifest; each native phase reads auth.json separately.
    manifest = {'version': '2.37.1', 'baseURL': BASE, 'libraryID': auth['libraryID'], 'userID': auth['userID'], 'serverID': str(uuid.uuid4()), 'items': found}
    output.mkdir(parents=True, exist_ok=True)
    target = output / 'manifest.json'
    temporary = output / 'manifest.temporary'
    temporary.write_text(json.dumps(manifest))
    temporary.chmod(0o600)
    temporary.replace(target)
    for fmt in formats:
        print('FIXTURE', fmt.upper(), found[fmt]['media']['metadata']['title'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        seed(args.output)
    except urllib.error.HTTPError as error:
        raise SystemExit('Fixture HTTP ' + str(error.code)) from None
    except Exception as error:
        raise SystemExit('Fixture preparation failed: ' + type(error).__name__) from None
