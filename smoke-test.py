#!/usr/bin/env python3
"""Exercise query tiers and actual disk thinning on an isolated temporary database."""
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="vm-downsampling-smoke-") as directory:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        process = None
        log = open(pathlib.Path(directory) / "server.log", "w+")

        def request(path, params=None, data=None):
            url = base + path
            if params:
                url += "?" + urllib.parse.urlencode(params)
            with urllib.request.urlopen(url, data=data, timeout=10) as response:
                return response.read().decode()

        def start(tiers):
            nonlocal process
            command = [binary, f"-httpListenAddr=127.0.0.1:{port}",
                       f"-storageDataPath={directory}/data", "-retentionPeriod=2y",
                       "-memory.allowedBytes=128MB", "-storage.minFreeDiskSpaceBytes=1MB"]
            if tiers:
                command.append("-downsampling.period=30d:5m,180d:1h")
            process = subprocess.Popen(command, stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("VictoriaMetrics exited during startup")
                try:
                    request("/health")
                    return
                except OSError:
                    time.sleep(0.1)
            raise RuntimeError("VictoriaMetrics failed to become healthy")

        def stop():
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=30)

        def export():
            result = {}
            text = request("/api/v1/export", {"match[]": '{__name__=~"smoke_.*"}',
                                              "start": "2020-01-01", "end": "2100-01-01"})
            for line in text.splitlines():
                row = json.loads(line)
                result.setdefault(row["metric"]["__name__"], []).extend(row["timestamps"])
            return {name: sorted(values) for name, values in result.items()}

        try:
            start(True)
            now = int(time.time())
            starts = {"smoke_old": (now - 200*86400)//3600*3600,
                      "smoke_middle": (now - 60*86400)//3600*3600,
                      "smoke_recent": now//3600*3600 - 3600}
            payload = b"\n".join(json.dumps({"metric": {"__name__": name},
                                           "timestamps": [(start+i*60)*1000 for i in range(60)],
                                           "values": list(range(60))}).encode()
                                  for name, start in starts.items())
            request("/api/v1/import", data=payload)
            request("/internal/force_flush", data=b"")
            thinned = export()
            assert {k: len(v) for k, v in thinned.items()} == {
                "smoke_old": 2, "smoke_middle": 13, "smoke_recent": 60}, thinned
            request("/internal/force_merge", data=b"")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                log.flush()
                if "forced merge for partition_prefix=\"\" has been successfully finished" in pathlib.Path(log.name).read_text():
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("forced merge did not complete")
            stop()
            # Disabling query downsampling proves that samples were removed on disk.
            start(False)
            persisted = export()
            assert persisted == thinned, (persisted, thinned)
            print("PASS: 60 samples per series -> 2 hourly, 13 five-minute, 60 recent; persisted after restart with tiers disabled")
        except Exception:
            stop()
            print(pathlib.Path(log.name).read_text(), file=sys.stderr)
            raise
        finally:
            stop()
            log.close()


if __name__ == "__main__":
    main()
