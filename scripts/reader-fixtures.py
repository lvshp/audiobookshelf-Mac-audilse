#!/usr/bin/env python3
"""Generate synthetic, DRM-free reading fixtures using only Python's stdlib.

RAR5 uses method 0 (stored), per https://www.rarlab.com/technote.htm .
AZW3 is a genuine MOBI8/KF8 database with FDST/SKEL/FRAG indexes, not renamed MOBI6.
These deliberately small fixtures do not cover encrypted/solid RAR or DRM/HUFF Kindle.
"""
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED, ZIP_DEFLATED
import argparse
import struct
import zlib


def paragraphs():
    return ''.join(f'<p id="p{i}">Paragraph {i}. The needle is here. Swift native reading preserves every position across navigation.</p>' for i in range(400))


def epub(path):
    with ZipFile(path, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
        archive.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=ZIP_DEFLATED)
        archive.writestr('OEBPS/content.opf', '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">shelfmac-reader-fixture</dc:identifier><dc:title>ShelfMac Reading EPUB</dc:title><dc:language>en</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>', compress_type=ZIP_DEFLATED)
        archive.writestr('OEBPS/nav.xhtml', '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Test Chapter</a></li></ol></nav></body></html>', compress_type=ZIP_DEFLATED)
        archive.writestr('OEBPS/chapter.xhtml', '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head><body><h1>Reader Verification</h1>' + paragraphs() + '</body></html>', compress_type=ZIP_DEFLATED)


def palm_database(records, title):
    header = bytearray(78)
    name = title.encode()[:31]
    header[:len(name)] = name
    header[60:68] = b'BOOKMOBI'
    struct.pack_into('>H', header, 76, len(records))
    offset = 78 + 8 * len(records)
    table = bytearray()
    for index, record in enumerate(records):
        table += struct.pack('>II', offset, index)
        offset += len(record)
    return header + table + b''.join(records)


def mobi6(path):
    text = ('<html><head><title>MOBI fixture</title></head><body><h1>MOBI Verification</h1>' + paragraphs() + '</body></html>').encode()
    title = b'MOBI fixture'
    record = bytearray(248 + len(title))
    struct.pack_into('>H', record, 0, 1)
    struct.pack_into('>I', record, 4, len(text))
    struct.pack_into('>H', record, 8, 1)
    struct.pack_into('>H', record, 10, 65535)
    record[16:20] = b'MOBI'
    for offset, value in [(20, 232), (24, 2), (28, 65001), (32, 1), (36, 6), (84, 248), (88, len(title)), (108, 2), (244, 0xffffffff)]:
        struct.pack_into('>I', record, offset, value)
    record[248:] = title
    path.write_bytes(palm_database([record, text], 'MOBI fixture'))


def mobi_varint(value):
    chunks = [value & 127]
    value >>= 7
    while value:
        chunks.insert(0, value & 127)
        value >>= 7
    chunks[-1] |= 128
    return bytes(chunks)


def index_header(**values):
    result = bytearray(56)
    result[:4] = b'INDX'
    fields = {'length': 4, 'type': 8, 'idxt': 20, 'records': 24, 'encoding': 28, 'total': 36, 'cncx': 52}
    values = {'length': 56, 'encoding': 65001, **values}
    for key, value in values.items():
        struct.pack_into('>I', result, fields[key], value)
    return result


def index_pair(tags, name, numbers, cncx=0):
    tagx = b'TAGX' + struct.pack('>II', 12 + 4 * len(tags), 1) + b''.join(bytes(tag) for tag in tags)
    entry = bytes([len(name)]) + name + bytes([sum(tag[2] for tag in tags)]) + b''.join(mobi_varint(value) for value in numbers)
    meta = index_header(records=1, total=1, cncx=cncx) + tagx
    data = index_header(type=1, records=1, idxt=56 + len(entry)) + entry + b'IDXT' + struct.pack('>H', 56)
    return [meta, data]


def azw3(path):
    prefix = b'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>KF8 fixture</title></head><body>'
    suffix = b'</body></html>'
    body = ('<h1>KF8 Verification</h1>' + paragraphs()).encode()
    skeleton = prefix + suffix
    raw = skeleton + body
    title = b'ShelfMac Reading AZW3'
    record = bytearray(292 + len(title))
    struct.pack_into('>H', record, 0, 1)
    struct.pack_into('>I', record, 4, len(raw))
    struct.pack_into('>H', record, 8, 1)
    struct.pack_into('>H', record, 10, 65535)
    record[16:20] = b'MOBI'
    for offset, value in [(20, 264), (24, 2), (28, 65001), (32, 1), (36, 8), (84, 292), (88, len(title)), (108, 8), (128, 64), (192, 2), (196, 1), (244, 0xffffffff), (248, 5), (252, 3), (260, 0xffffffff)]:
        struct.pack_into('>I', record, offset, value)
    record[280:292] = b'EXTH' + struct.pack('>II', 12, 0)
    record[292:] = title
    fdst = b'FDST' + struct.pack('>IIII', 12, 1, 0, len(raw))
    skel = index_pair([(1, 1, 1, 0), (6, 2, 2, 0)], b'0', [1, 0, len(skeleton)])
    frag = index_pair([(2, 1, 1, 0), (4, 1, 2, 0), (6, 2, 4, 0)], str(len(prefix)).encode(), [0, 0, 0, len(body)], cncx=1)
    path.write_bytes(palm_database([record, raw, fdst, *skel, *frag, mobi_varint(4) + b'body'], 'KF8 fixture'))


def png(page):
    width, height = 320, 420
    # Each page has a distinct color and visible page-number bars, all synthetic.
    colors = [(235, 65, 65), (65, 195, 85), (65, 105, 235)]
    color = colors[page - 1]
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            bar = 80 < y < 340 and any(35 + i * 90 < x < 75 + i * 90 for i in range(page))
            rows += bytes((255, 255, 255) if bar else color)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def rar_varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return result


def rar_block(header, data=b''):
    header = rar_varint(len(header)) + header
    return struct.pack('<I', zlib.crc32(header)) + header + data


def comics(directory):
    entries = [('pages/10.png', png(2)), ('pages/2.png', png(1)), ('pages/11.png', png(3))]
    with ZipFile(directory / 'fixture.cbz', 'w', compression=ZIP_DEFLATED) as archive:
        for name, data in entries:
            archive.writestr(name, data)
        archive.writestr('.hidden.png', png(3))
    rar = bytearray(b'Rar!\x1a\x07\x01\x00') + rar_block(bytes([1, 0, 0]))
    for name, data in entries:
        filename = name.encode()
        header = bytes([2, 2]) + rar_varint(len(data)) + bytes([4]) + rar_varint(len(data)) + rar_varint(0o100644) + struct.pack('<I', zlib.crc32(data)) + bytes([0, 1]) + rar_varint(len(filename)) + filename
        rar += rar_block(header, data)
    rar += rar_block(bytes([5, 0, 0]))
    (directory / 'fixture.cbr').write_bytes(rar)


def pdf(path):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    for page in range(1, 4):
        content_id = 5 + (page - 1) * 2
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 3 0 R >> >> /Contents {content_id} 0 R >>'.encode())
        content = f'BT /F1 24 Tf 50 720 Td (ShelfMac PDF page {page}) Tj 0 -48 Td (The needle is on page {page}.) Tj ET'.encode()
        objects.append(b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' + content + b'\nendstream')
    output = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output += f'{index} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(output)
    output += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]:
        output += f'{offset:010d} 00000 n \n'.encode()
    output += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    path.write_bytes(output)


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    epub(directory / 'fixture.epub')
    mobi6(directory / 'fixture.mobi')
    azw3(directory / 'fixture.azw3')
    pdf(directory / 'fixture.pdf')
    comics(directory)
    print('Generated synthetic EPUB, MOBI6, KF8/AZW3, PDF, CBZ and RAR5/CBR')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    generate(parser.parse_args().directory)
