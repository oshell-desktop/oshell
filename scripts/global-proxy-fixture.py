# SPDX-License-Identifier: GPL-3.0-only
"""Loopback SOCKS5 fixture for the native global-policy integration tests."""
import socket, struct, threading, select

class ProxyFixture:
    def __init__(self):
        self.connections = 0
        self.errors = []
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try: peer, _ = self.listener.accept()
            except OSError: return
            threading.Thread(target=self.handle, args=(peer,), daemon=True).start()

    @staticmethod
    def exact(peer, size):
        data = b''
        while len(data) < size:
            chunk = peer.recv(size - len(data))
            if not chunk: raise EOFError()
            data += chunk
        return data

    def handle(self, peer):
        target = None
        try:
            peer.settimeout(15)
            version, count = self.exact(peer, 2)
            assert version == 5 and 0 in self.exact(peer, count)
            peer.sendall(b'\x05\x00')
            version, command, reserved, kind = self.exact(peer, 4)
            assert (version, command, reserved) == (5, 1, 0)
            if kind == 1: host = socket.inet_ntoa(self.exact(peer, 4))
            elif kind == 3: host = self.exact(peer, self.exact(peer, 1)[0]).decode()
            else: raise ValueError('Fixture only permits loopback IPv4')
            port = struct.unpack('!H', self.exact(peer, 2))[0]
            assert host == '127.0.0.1'
            target = socket.create_connection((host, port), timeout=10)
            self.connections += 1
            peer.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
            peers = [peer, target]
            while peers:
                ready, _, _ = select.select(peers, [], [], 45)
                if not ready: break
                for source in ready:
                    data = source.recv(65536)
                    destination = target if source is peer else peer
                    if data: destination.sendall(data)
                    else:
                        peers.remove(source)
                        destination.shutdown(socket.SHUT_WR)
        except (ConnectionError, EOFError, OSError):
            pass  # Cancellation and failed SFTP channels intentionally close transports.
        except Exception as error: self.errors.append(str(error))
        finally:
            peer.close()
            if target: target.close()

    def close(self):
        self.listener.close()
