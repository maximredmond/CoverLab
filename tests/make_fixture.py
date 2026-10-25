"""Generate redistributable EPUB/PNG test fixtures using only the standard library."""
import pathlib
import struct
import sys
import zipfile
import zlib

dest = pathlib.Path(sys.argv[1])
dest.mkdir(parents=True, exist_ok=True)

def png(width, height, rgb):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = (b'\0' + bytes(rgb) * width) * height
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))

cover = png(480, 720, (180, 180, 180))
(dest / 'replacement.png').write_bytes(png(600, 900, (60, 60, 60)))
(dest / 'previous.png').write_bytes(png(300, 450, (100, 100, 100)))
for i in range(1,7):
    (dest / f'candidate-{i}.png').write_bytes(png(600, 900, (i * 30, i * 30, i * 30)))
for name, identifiers in [
    ('book.epub', '<dc:identifier id="bookid">urn:isbn:9780140449266</dc:identifier>'),
    ('[download-site.example] unusual filename - no ISBN.epub', '<dc:identifier id="bookid">urn:uuid:fixture</dc:identifier>'),
]:
    with zipfile.ZipFile(dest / name, 'w') as epub:
        epub.writestr('mimetype', 'application/epub+zip')
        epub.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        epub.writestr('OEBPS/content.opf', f'''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>The Count of Monte Cristo</dc:title><dc:creator>Alexandre Dumas</dc:creator>
<dc:language>en</dc:language>{identifiers}<meta name="cover" content="cover"/>
</metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
<item id="cover" href="cover.png" media-type="image/png"/></manifest>
<spine><itemref idref="text"/></spine></package>''')
        epub.writestr('OEBPS/text.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head><body><h1>CoverLab test fixture</h1><p>Original text.</p></body></html>')
        epub.writestr('OEBPS/cover.png', cover)
print(dest)
