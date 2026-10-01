#!/usr/bin/env python3
"""Package an openjdk21-wasm-link build for static hosting (GitHub Pages).

  python3 package-site.py out              # writes site/
  python3 package-site.py out -o public --chunk-mb 20

Every file in BUILD larger than the chunk size (the .data file, and the .wasm if
it is big) is split into chunks under data/ and listed in data/manifest.json.
Smaller files are copied as they are. index.html (installer page) and
coi-serviceworker.js are added; the worker rebuilds the split files in the
browser from the chunks that index.html stores in Cache Storage.
"""
import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TYPES = {'.wasm': 'application/wasm', '.js': 'text/javascript'}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('build', type=Path, help='link output directory, e.g. out/')
    ap.add_argument('-o', '--site', type=Path, default=Path('site'))
    ap.add_argument('--app', help='app page inside BUILD (default: the only .html there)')
    ap.add_argument('--chunk-mb', type=int, default=20)
    ap.add_argument('--index', type=Path, default=HERE / 'index.html')
    ap.add_argument('--sw', type=Path, default=HERE / 'coi-serviceworker.js')
    a = ap.parse_args()

    if not a.build.is_dir():
        sys.exit(f'{a.build} is not a directory')
    for p in (a.index, a.sw):
        if not p.is_file():
            sys.exit(f'missing {p}')
    pages = sorted(p.name for p in a.build.glob('*.html') if p.name != 'index.html')
    app = a.app or (pages[0] if len(pages) == 1 else None)
    if not app:
        sys.exit(f'use --app: found {pages or "no .html"} in {a.build}')

    chunk = a.chunk_mb * 1024 * 1024
    shutil.rmtree(a.site / 'data', ignore_errors=True)
    (a.site / 'data').mkdir(parents=True)

    files, version = [], hashlib.sha256()
    for src in sorted(p for p in a.build.rglob('*') if p.is_file()):
        rel = src.relative_to(a.build).as_posix()
        if rel in ('index.html', 'coi-serviceworker.js'):
            continue
        size = src.stat().st_size
        if size <= chunk:
            dst = a.site / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            continue
        chunks = []
        with src.open('rb') as f:
            for n in range(-(-size // chunk)):
                buf = f.read(chunk)
                url = f"data/{rel.replace('/', '__')}.{n:03d}"
                (a.site / url).write_bytes(buf)
                digest = hashlib.sha256(buf).hexdigest()
                chunks.append({'url': url, 'size': len(buf), 'sha256': digest})
                version.update(digest.encode())
        version.update(rel.encode())
        files.append({'path': rel, 'size': size,
                      'type': TYPES.get(src.suffix, 'application/octet-stream'),
                      'chunks': chunks})
        print(f'split {rel}: {size / 2**20:.0f} MB into {len(chunks)} chunks')

    if not files:
        sys.exit(f'no file in {a.build} is larger than {a.chunk_mb} MB; nothing to split')

    manifest = {'version': version.hexdigest()[:12], 'built': int(time.time()), 'app': app,
                'total': sum(f['size'] for f in files), 'files': files}
    (a.site / 'data' / 'manifest.json').write_text(json.dumps(manifest, indent=1))
    shutil.copy2(a.index, a.site / 'index.html')
    shutil.copy2(a.sw, a.site / 'coi-serviceworker.js')
    (a.site / '.nojekyll').touch()   # serve files as they are, no Jekyll processing

    total = sum(p.stat().st_size for p in a.site.rglob('*') if p.is_file())
    print(f'wrote {a.site}/: {total / 2**20:.0f} MB in total, '
          f'{manifest["total"] / 2**20:.0f} MB downloaded by the Install button, '
          f'version {manifest["version"]}')
    if total > 2**30:
        print('warning: GitHub Pages limits published sites to 1 GB; trim the IDE directory '
              '(jbr/, unused plugins) before building', file=sys.stderr)


if __name__ == '__main__':
    main()
