#!/usr/bin/env python3
"""NETSYNC server: hands a DOS PC the files that changed since its last sync.

The PC runs NETSYNC.BAT, which fetches /sync.bat?since=<generation> with
mTCP HTGET and runs it.  The generated batch downloads only the files that
changed since that generation and finally stores the new generation number
on the PC.  No clock on the PC is needed, the server keeps the snapshots.

    python3 netsync.py /srv/retro            # serve on port 8080
    python3 netsync.py --port 80 --delete /srv/retro

Python 3.8+, standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlsplit

KEEP_GENERATIONS = 50
# DOS keeps 127 characters of a batch line; the variables are expanded first
MAX_LINE = 126
ASSUMED_DST = len("C:\\")
ASSUMED_SRV = len("192.168.100.100:8080")
DOS_NAME = re.compile(r"^[A-Z0-9_$~!#%&'(){}@^`-]{1,8}(\.[A-Z0-9_$~!#%&'(){}@^`-]{1,3})?$")

Snapshot = dict  # DOS path -> [size, mtime_ns]


def dos_name(part: str) -> str | None:
    upper = part.upper()
    return upper if DOS_NAME.match(upper) else None


def scan(root: Path) -> tuple[Snapshot, list[str]]:
    """Snapshot of every file below root with a valid 8.3 path."""
    files: Snapshot = {}
    skipped: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root)
        dos_dir = [dos_name(p) for p in rel_dir.parts]
        if None in dos_dir:
            skipped.append(str(rel_dir) + "/")
            dirnames[:] = []
            continue
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            dos = dos_name(name)
            if dos is None:
                skipped.append(str(rel_dir / name))
                continue
            st = (Path(dirpath) / name).stat()
            files["\\".join(dos_dir + [dos])] = [st.st_size, st.st_mtime_ns]
    return files, skipped


class State:
    """Numbered snapshots of the served directory, kept in a JSON file."""

    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        try:
            data = json.loads(path.read_text())
            self.generations = {int(k): v for k, v in data["generations"].items()}
        except (OSError, ValueError, KeyError):
            self.generations = {}

    def current(self, files: Snapshot) -> int:
        with self.lock:
            if self.generations:
                last = max(self.generations)
                if self.generations[last] == files:
                    return last
            else:
                last = 0
            gen = last + 1
            self.generations[gen] = files
            for old in sorted(self.generations)[:-KEEP_GENERATIONS]:
                del self.generations[old]
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"generations": self.generations}))
            tmp.replace(self.path)
            return gen

    def known(self, gen: int) -> Snapshot | None:
        with self.lock:
            return self.generations.get(gen)


def make_batch(files: Snapshot, gen: int, old: Snapshot | None, skipped: list[str],
               delete: bool) -> str:
    """The batch the PC runs; %SYNCSRV% and %SYNCDST% come from NETSYNC.BAT."""
    base = old or {}
    changed = [p for p in files if base.get(p) != files[p]]
    removed = [p for p in base if p not in files]
    out = ["@ECHO OFF",
           f"REM NETSYNC generation {gen}, {len(changed)} changed, {len(removed)} removed"]
    if old is None:
        out.append("ECHO NETSYNC: full sync")
    for s in skipped:
        out.append(f"REM skipped, not an 8.3 name: {s}")
    made = set()
    for path in changed:
        parts = path.split("\\")
        for i in range(1, len(parts)):
            d = "\\".join(parts[:i])
            if d not in made:
                made.add(d)
                out.append(f"IF NOT EXIST %SYNCDST%{d}\\NUL MD %SYNCDST%{d}")
        url = "/f/" + quote("/".join(parts))
        line = f"HTGET -o %SYNCDST%{path} http://%SYNCSRV%{url}"
        length = len(line) - len("%SYNCDST%%SYNCSRV%") + ASSUMED_DST + ASSUMED_SRV
        if length > MAX_LINE:
            out.append(f"REM skipped, path too long for a batch line: {path}")
            continue
        out += [f"ECHO {path}", line, "IF ERRORLEVEL 1 GOTO FAIL"]
    for path in removed:
        if delete:
            out.append(f"IF EXIST %SYNCDST%{path} DEL %SYNCDST%{path}")
        else:
            out.append(f"REM removed on the server: {path}")
    out += [f"ECHO SET SYNCGEN={gen}>%SYNCSTATE%",
            f"ECHO NETSYNC: {len(changed)} file(s) updated",
            "GOTO END",
            ":FAIL",
            "ECHO NETSYNC: download failed, next run tries again",
            ":END"]
    return "\r\n".join(out) + "\r\n"


class Handler(BaseHTTPRequestHandler):
    server_version = "NETSYNC/1"
    root: Path
    state: State
    delete: bool

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        if url.path.lower() == "/sync.bat":
            self.send_batch(parse_qs(url.query))
        elif url.path.startswith("/f/"):
            self.send_file(unquote(url.path[3:]))
        else:
            self.send_error(404)

    def send_batch(self, query: dict) -> None:
        files, skipped = scan(self.root)
        gen = self.state.current(files)
        try:
            since = int(query.get("since", ["0"])[0] or 0)
        except ValueError:
            since = 0
        old = self.state.known(since) if since else None
        body = make_batch(files, gen, old, skipped, self.delete).encode("ascii", "replace")
        self.reply(body, "text/plain")

    def send_file(self, rel: str) -> None:
        # the URL carries the DOS (upper case) name, find the real file
        current = self.root
        for part in rel.split("/"):
            match = None
            if current.is_dir() and part not in ("", ".", ".."):
                match = next((c for c in current.iterdir() if c.name.upper() == part.upper()), None)
            if match is None:
                self.send_error(404)
                return
            current = match
        if not current.is_file():
            self.send_error(404)
            return
        self.reply(current.read_bytes(), "application/octet-stream")

    def reply(self, body: bytes, kind: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("directory", type=Path, help="directory mirrored to the PC")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="")
    ap.add_argument("--state", type=Path, help="state file (default ~/.netsync/<dir>.json)")
    ap.add_argument("--delete", action="store_true",
                    help="delete files on the PC that were removed on the server")
    args = ap.parse_args(argv)
    root = args.directory.resolve()
    if not root.is_dir():
        ap.error(f"{root} is not a directory")
    state_file = args.state
    if state_file is None:
        tag = hashlib.sha1(str(root).encode()).hexdigest()[:8]
        state_file = Path.home() / ".netsync" / f"{root.name}-{tag}.json"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    Handler.root, Handler.state, Handler.delete = root, State(state_file), args.delete
    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"NETSYNC serving {root} on port {args.port}, state {state_file}", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
