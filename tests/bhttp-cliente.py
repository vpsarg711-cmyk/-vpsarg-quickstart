#!/usr/bin/env python3
"""Cliente BHTTP mínimo, SOLO para pruebas de laboratorio.

Implementa el protocolo de server-source.go (SuperFlash BHTTP 2.4.1) para usarlo como
ProxyCommand de ssh:
  ssh -o ProxyCommand="python3 bhttp-cliente.py 127.0.0.1 8001" usuario@bhttp
Conecta stdin/stdout con el SSH que está detrás de bhttp-shim / bhttp-server.
No es un cliente real (DTunnel u otro): solo prueba que el camino llega a SSH.
Cada pedido usa una conexión TCP nueva, como un cliente de "1 respuesta".
"""
import hashlib
import os
import socket
import struct
import sys
import threading
import time

UPLOAD, BATCH, ACK = 1, 3, 4
STATUS_OK, STATUS_ERROR, STATUS_DATA = 0, 1, 2


def crypt(data, sid, mode, seq, response):
    out = bytearray(len(data))
    off = 0
    block = 0
    while off < len(data):
        state = sid + bytes([mode]) + struct.pack(">Q", seq) + bytes([1 if response else 0]) + struct.pack(">I", block)
        key = hashlib.sha256(state).digest()
        n = min(32, len(data) - off)
        for i in range(n):
            out[off + i] = data[off + i] ^ key[i]
        off += n
        block += 1
    return bytes(out)


def read_exact(s, n):
    buf = b""
    while len(buf) < n:
        d = s.recv(n - len(buf))
        if not d:
            raise EOFError
        buf += d
    return buf


def request(addr, mode, sid, seq, body, responses=1):
    """Envía un pedido y devuelve la lista de (estado, cuerpo) de las respuestas."""
    for _ in range(5):
        try:
            s = socket.create_connection(addr, timeout=30)
            try:
                s.sendall(bytes([mode]) + sid + struct.pack(">Q", seq) + struct.pack(">I", len(body)) + body)
                out = []
                for _ in range(responses):
                    hdr = read_exact(s, 5)
                    n = struct.unpack(">I", hdr[1:5])[0]
                    out.append((hdr[0], read_exact(s, n)))
                    if hdr[0] == STATUS_ERROR:
                        break
                return out
            finally:
                s.close()
        except (OSError, EOFError):
            time.sleep(0.2)
    raise SystemExit("bhttp-cliente: sin respuesta de %s:%d" % addr)


def main():
    addr = (sys.argv[1], int(sys.argv[2]))
    sid = os.urandom(16)
    st, body = request(addr, UPLOAD, sid, 0, b"")[0]
    if st != STATUS_OK:
        raise SystemExit("bhttp-cliente: registro rechazado: %r" % body)
    out = sys.stdout.buffer

    def uploader():
        seq = 0
        stdin = sys.stdin.buffer.raw
        while True:
            data = stdin.read(32768)
            if not data:
                os._exit(0)
            st, body = request(addr, UPLOAD, sid, seq, crypt(data, sid, UPLOAD, seq, False))[0]
            if st != STATUS_OK:
                os._exit(1)
            seq += 1

    threading.Thread(target=uploader, daemon=True).start()
    seq = 0
    count = 8
    while True:
        params = struct.pack(">I", 65536) + bytes([0, count])
        res = request(addr, BATCH, sid, seq, crypt(params, sid, BATCH, seq, False), responses=count)
        got = 0
        for i, (st, body) in enumerate(res):
            if st != STATUS_DATA:
                os._exit(1)
            n = struct.unpack(">I", body[:4])[0]
            chunk = crypt(body[4:4 + n], sid, BATCH, seq + i, True)
            if chunk:
                out.write(chunk)
                got += len(chunk)
        out.flush()
        request(addr, ACK, sid, seq + count - 1, b"")
        seq += count
        if not got:
            time.sleep(0.03)


if __name__ == "__main__":
    main()
