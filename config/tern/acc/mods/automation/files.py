"""File operations that preserve the automation runner's existing on-disk format."""
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import unicodedata


def replace(path, text, expected):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with (path.parent / '.acc-write.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = path.read_text() if path.exists() else None
        if current != expected:
            raise RuntimeError('File changed since it was read; refresh and try again.')
        if expected is None:
            with path.open('x') as out:
                out.write(text)
            return
        fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as out:
                out.write(text)
            if path.read_text() != expected:
                raise RuntimeError('Finding changed while updating; refresh and try again.')
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


def main():
    action = sys.argv[1]
    data = json.load(sys.stdin)
    if action == 'mark':
        doc = json.loads(data['expected'])
        doc.update(data['patch'])
        replace(data['path'], json.dumps(doc, indent=2) + '\n', data['expected'])
        print(json.dumps(doc))
    elif action == 'create':
        import re
        name = ' '.join(data['name'].split())
        slug = re.sub('[^a-z0-9]+', '-', unicodedata.normalize('NFD', name).lower()).strip('-')[:40]
        if not slug:
            raise RuntimeError('Give it a name.')
        path = Path(data['dir']) / 'jobs' / (slug + '.md')
        replace(path, data['text'], None)
        print(json.dumps({'id': slug}))
    elif action == 'scan':
        root = Path(data['root'])
        items = sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime, reverse=True) if root.exists() else []
        print(json.dumps([p.name for p in items[:20]]))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
