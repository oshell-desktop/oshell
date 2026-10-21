#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""An isolated SSH password-auth server, never touching macOS account credentials."""
import json
import secrets
import socket
import sys
import threading
from pathlib import Path
import paramiko

root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
key = paramiko.RSAKey.generate(2048)
fixture = {"user": "oshell-fixture", "password": secrets.token_urlsafe(24), "master": secrets.token_urlsafe(24)}
fixture_path = root / "auth-fixture.json"
fixture_path.write_text(json.dumps(fixture)); fixture_path.chmod(0o600)
(root / "auth-known-hosts").write_text(f"[127.0.0.1]:22230 {key.get_name()} {key.get_base64()}\n")

class Server(paramiko.ServerInterface):
    def __init__(self): self.shell = threading.Event()
    def get_allowed_auths(self, username): return "password"
    def check_auth_password(self, username, password):
        accepted = username == fixture["user"] and password == fixture["password"]
        (root / "auth-server-result.json").write_text(json.dumps({"passwordAccepted": accepted}))
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, *args): return True
    def check_channel_shell_request(self, channel): self.shell.set(); return True

def connection(client):
    transport = paramiko.Transport(client); transport.add_server_key(key); server = Server()
    try:
        transport.start_server(server=server)
        channel = transport.accept(15)
        if channel and server.shell.wait(15):
            channel.send(b"\r\nOSHELL_PASSWORD_AUTH_OK\r\nfixture$ ")
            channel.settimeout(10)
            try: channel.recv(1024)
            except Exception: pass
    except Exception: pass
    finally: transport.close()

listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 22230)); listener.listen(4)
print("Password test server ready", flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=connection, args=(client,), daemon=True).start()
