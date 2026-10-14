"""NETSYNC: server snapshots and the generated batch, run by a tiny batch model."""

import os
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "sync"))
import netsync  # noqa: E402

DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class DosPc:
    """Runs the subset of COMMAND.COM that NETSYNC.BAT and the generated batch use."""

    def __init__(self, drive: Path, server: str):
        self.drive = drive
        self.env = {"SYNCSRV": server}
        self.errorlevel = 0
        self.output = []

    def path(self, dos: str) -> Path:
        assert dos.upper().startswith("C:\\"), dos
        rest = [p for p in dos[3:].split("\\") if p]
        return self.drive.joinpath(*rest) if rest else self.drive

    def expand(self, line: str) -> str:
        out, i = "", 0
        while i < len(line):
            if line[i] == "%":
                j = line.index("%", i + 1)
                out += self.env.get(line[i + 1:j].upper(), "")
                i = j + 1
            else:
                out += line[i]
                i += 1
        return out

    def run(self, lines: list[str]) -> None:
        labels = {l[1:].strip().upper(): n for n, l in enumerate(lines) if l.startswith(":")}
        pc = 0
        while pc < len(lines):
            line = self.expand(lines[pc].strip())
            pc += 1
            if not line or line.startswith(":") or line.upper().startswith("REM"):
                continue
            line = line.lstrip("@")
            jump = self.command(line)
            if jump == "EXIT":
                return
            if jump is not None:
                pc = labels[jump]

    def command(self, line: str):
        word, _, rest = line.partition(" ")
        word = word.upper()
        if word == "IF":
            return self.cond(rest)
        if word == "ECHO":
            if rest.upper() == "OFF":
                return None
            if ">" in rest:
                text, target = rest.rsplit(">", 1)
                self.path(target.strip()).write_bytes(text.encode() + b"\r\n")
            else:
                self.output.append(rest)
            return None
        if word == "GOTO":
            return rest.strip().upper()
        if word == "SET":
            name, _, value = rest.partition("=")
            if value:
                self.env[name.upper()] = value
            else:
                self.env.pop(name.upper(), None)
            return None
        if word == "CALL":
            target = self.path(rest.strip())
            self.run(target.read_text().splitlines())
            return None
        if word == "MD":
            self.path(rest.strip()).mkdir()
            return None
        if word == "DEL":
            self.path(rest.strip()).unlink()
            return None
        if word == "HTGET":
            args = rest.split()
            assert args[0] == "-o"
            try:
                with DIRECT.open(args[2], timeout=5) as r:
                    self.path(args[1]).write_bytes(r.read())
                self.errorlevel = 0
            except OSError:
                self.errorlevel = 1
            return None
        raise AssertionError(f"unknown command {line!r}")

    def cond(self, rest: str):
        if rest.upper().startswith("NOT "):
            ok, rest = False, rest[4:]
        else:
            ok = True
        if rest.upper().startswith("EXIST "):
            name, _, cmd = rest[6:].partition(" ")
            if name.upper().endswith("\\NUL"):
                hit = self.path(name[:-4]).is_dir()
            else:
                hit = self.path(name).is_file()
        elif rest.upper().startswith("ERRORLEVEL "):
            level, _, cmd = rest[11:].partition(" ")
            hit = self.errorlevel >= int(level)
        else:
            left, _, tail = rest.partition("==")
            right, _, cmd = tail.partition(" ")
            hit = left == right
        if hit == ok:
            return self.command(cmd)
        return None


class NetSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.srv = base / "srv"
        self.drive = base / "c"
        self.srv.mkdir()
        self.drive.mkdir()
        netsync.Handler.root = self.srv
        netsync.Handler.state = netsync.State(base / "state.json")
        netsync.Handler.delete = False
        netsync.Handler.log_message = lambda *a: None
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), netsync.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.server = f"127.0.0.1:{self.httpd.server_address[1]}"
        self.batch = (Path(__file__).resolve().parent.parent / "sync" / "NETSYNC.BAT").read_text()

    def tearDown(self):
        self.stop()
        self.tmp.cleanup()

    def stop(self):
        if self.httpd:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None

    def sync(self) -> DosPc:
        pc = DosPc(self.drive, self.server)
        pc.run(self.batch.splitlines())
        return pc

    def put(self, rel: str, data: bytes, mtime: int = 1_000_000_000):
        p = self.srv / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        os.utime(p, (mtime, mtime))

    def test_full_then_incremental(self):
        self.put("games/doom.exe", b"A" * 100)
        self.put("readme.txt", b"hello")
        pc = self.sync()
        self.assertEqual((self.drive / "GAMES" / "DOOM.EXE").read_bytes(), b"A" * 100)
        self.assertEqual((self.drive / "README.TXT").read_bytes(), b"hello")
        self.assertIn("NETSYNC: 2 file(s) updated", pc.output)
        self.assertFalse((self.drive / "NSRUN.BAT").exists())

        pc = self.sync()
        self.assertIn("NETSYNC: 0 file(s) updated", pc.output)

        self.put("readme.txt", b"changed", mtime=1_000_000_100)
        pc = self.sync()
        self.assertIn("README.TXT", pc.output)
        self.assertNotIn("GAMES\\DOOM.EXE", pc.output)
        self.assertEqual((self.drive / "README.TXT").read_bytes(), b"changed")

    def test_unknown_generation_means_full_sync(self):
        self.put("a.txt", b"1")
        self.sync()
        (self.drive / "NSGEN.BAT").write_text("SET SYNCGEN=999\r\n")
        pc = self.sync()
        self.assertIn("NETSYNC: full sync", pc.output)
        self.assertIn("NETSYNC: 1 file(s) updated", pc.output)

    def test_failed_download_keeps_generation(self):
        self.put("a.txt", b"1")
        self.sync()
        gen = (self.drive / "NSGEN.BAT").read_text()
        self.put("b.txt", b"2")
        files, skipped = netsync.scan(self.srv)
        new = netsync.Handler.state.current(files)
        text = netsync.make_batch(files, new, netsync.Handler.state.known(1), skipped, False)
        text = text.replace("/f/B.TXT", "/f/MISSING.TXT")
        pc = DosPc(self.drive, self.server)
        pc.env.update(SYNCDST="C:\\", SYNCSTATE="C:\\NSGEN.BAT")
        pc.run(text.splitlines())
        self.assertIn("NETSYNC: download failed, next run tries again", pc.output)
        self.assertEqual((self.drive / "NSGEN.BAT").read_text(), gen)

    def test_non_dos_names_are_skipped(self):
        self.put("long file name.txt", b"x")
        self.put("toolongname/a.txt", b"x")
        self.put("ok.txt", b"x")
        files, skipped = netsync.scan(self.srv)
        self.assertEqual(list(files), ["OK.TXT"])
        self.assertEqual(sorted(skipped), ["long file name.txt", "toolongname/"])

    def test_removed_files(self):
        self.put("a.txt", b"1")
        self.put("b.txt", b"2")
        self.sync()
        (self.srv / "b.txt").unlink()
        self.sync()
        self.assertTrue((self.drive / "B.TXT").exists())
        netsync.Handler.delete = True
        self.put("b.txt", b"2")
        self.sync()
        (self.srv / "b.txt").unlink()
        self.sync()
        self.assertFalse((self.drive / "B.TXT").exists())

    def test_no_server_set(self):
        pc = DosPc(self.drive, self.server)
        del pc.env["SYNCSRV"]
        pc.run(self.batch.splitlines())
        self.assertIn("NETSYNC: SET SYNCSRV=server:port first", pc.output)

    def test_server_down(self):
        self.stop()
        pc = self.sync()
        self.assertIn(f"NETSYNC: server {self.server} not reachable", pc.output)


if __name__ == "__main__":
    unittest.main()
