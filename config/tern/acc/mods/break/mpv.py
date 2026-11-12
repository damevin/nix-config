"""Break's mpv helper.

  mpv.py ipc SOCKET COMMANDS_JSON   run mpv IPC commands, print one reply per command as a JSON list
  mpv.py launch LOGFILE COMMAND     start COMMAND detached from the caller (mpv outlives the plugin)
"""
import json
import socket
import subprocess
import sys


def ipc(path, cmds):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(1.5)
    try:
        s.connect(path)
    except OSError:
        print("null")
        return
    out = {}
    buf = b""
    for i, c in enumerate(cmds):
        s.sendall((json.dumps({"command": c, "request_id": i + 1}) + "\n").encode())
    try:
        while len(out) < len(cmds):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for line in lines:
                m = json.loads(line)
                if "request_id" in m and m["request_id"]:
                    out[m["request_id"]] = m.get("data")
    except OSError:
        pass
    print(json.dumps([out.get(i + 1) for i in range(len(cmds))]))


def launch(log_path, command):
    log = open(log_path, "w")
    subprocess.Popen(["sh", "-c", command], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


if sys.argv[1] == "ipc":
    ipc(sys.argv[2], json.loads(sys.argv[3]))
elif sys.argv[1] == "launch":
    launch(sys.argv[2], sys.argv[3])
