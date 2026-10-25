"""Build an installable plugin archive without including tests or runtime state."""
import pathlib
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
dest = root / 'dist'
dest.mkdir(exist_ok=True)
archive = dest / 'coverlab-0.1.0.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
    for path in sorted((root / 'coverlab.koplugin').rglob('*')):
        if path.is_file():
            output.write(path, path.relative_to(root))
print(archive)
