#!/usr/bin/env python3
"""VPS ARG QuickStart - servicio de autorización de instalaciones.

Corre en un servidor del administrador (nunca en una VPS de clientes), detrás de
Caddy o nginx con TLS. Solo usa la biblioteca estándar de Python 3.8+ y SQLite.

Un token autoriza UNA instalación completa de VPS ARG QuickStart:
  emitido -> reservado -> consumido   (o revocado; una reserva sin confirmar vence)
El token en claro se muestra una sola vez al emitirlo; la base guarda solo su SHA-256.

API (POST, JSON; el token va en el cuerpo, nunca en la URL):
  /v1/reservar  {token, hostname}         -> {resultado: reservado, token_id, reserva_id, vence_reserva}
  /v1/confirmar {token, reserva_id}       -> {resultado: consumido}
  /v1/liberar   {token, reserva_id}       -> {resultado: liberado}
  GET /v1/salud                           -> {ok: true}
Rechazos: HTTP 403 con {resultado: rechazado, motivo: invalido|vencido|revocado|consumido|en_uso|reserva}.

Administración (solo en el servidor, sin endpoints expuestos):
  vpsarg-autorizacion.py emitir [--vence AAAA-MM-DD] [--nota TEXTO]
  vpsarg-autorizacion.py listar | ver ID | revocar ID | liberar ID | confirmar ID
  vpsarg-autorizacion.py servir [--escuchar 127.0.0.1:8090]
Opción común: --db RUTA (por defecto /var/lib/vpsarg-autorizacion/tokens.db).
"""

import argparse
import datetime
import hashlib
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_DEFAULT = "/var/lib/vpsarg-autorizacion/tokens.db"
TOKEN_RE = re.compile(r"^vpsarg_[A-Za-z0-9_-]{43}$")
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
RESERVA_RE = re.compile(r"^[A-Za-z0-9_-]{22}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]{1,64}$")
NOTA_RE = re.compile(r"^[A-Za-z0-9 ._@-]{0,60}$")
RESERVA_SEGUNDOS = 30 * 60
MAX_BODY = 4096
LIMITE_POR_MINUTO = 10
RUTAS = ("/v1/reservar", "/v1/confirmar", "/v1/liberar", "/v1/salud")

SCHEMA = """
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY,
  hash TEXT NOT NULL UNIQUE,
  nota TEXT NOT NULL DEFAULT '',
  vence TEXT NOT NULL,
  estado TEXT NOT NULL CHECK (estado IN ('emitido','reservado','consumido','revocado')),
  creado TEXT NOT NULL,
  reserva_id TEXT,
  reserva_vence INTEGER,
  reserva_host TEXT,
  reserva_ip TEXT,
  consumido TEXT,
  consumido_ip TEXT,
  revocado TEXT
);
CREATE TABLE IF NOT EXISTS eventos (
  fecha TEXT NOT NULL,
  token_id TEXT,
  accion TEXT NOT NULL,
  ip TEXT,
  resultado TEXT NOT NULL
);
"""


def ahora_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hoy():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def token_hash(token):
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def conectar(path):
    con = sqlite3.connect(path, timeout=30, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=30000")
    con.executescript(SCHEMA)
    return con


def evento(con, token_id, accion, ip, resultado):
    con.execute("INSERT INTO eventos VALUES (?,?,?,?,?)", (ahora_iso(), token_id, accion, ip, resultado))


# ------------------------------------------------------------------ operaciones
def reservar(con, token, hostname, ip):
    h = token_hash(token)
    now = int(time.time())
    con.execute("BEGIN IMMEDIATE")
    try:
        row = con.execute("SELECT * FROM tokens WHERE hash=?", (h,)).fetchone()
        motivo = None
        if row is None:
            motivo = "invalido"
        elif row["estado"] == "revocado":
            motivo = "revocado"
        elif row["estado"] == "consumido":
            motivo = "consumido"
        elif row["vence"] < hoy():
            motivo = "vencido"
        elif row["estado"] == "reservado" and row["reserva_vence"] >= now:
            motivo = "en_uso"
        if motivo:
            evento(con, row["id"] if row else None, "reservar", ip, motivo)
            con.execute("COMMIT")
            return 403, {"resultado": "rechazado", "motivo": motivo}
        reserva = secrets.token_urlsafe(16)
        cur = con.execute(
            "UPDATE tokens SET estado='reservado', reserva_id=?, reserva_vence=?, reserva_host=?, reserva_ip=? "
            "WHERE hash=? AND (estado='emitido' OR (estado='reservado' AND reserva_vence<?))",
            (reserva, now + RESERVA_SEGUNDOS, hostname, ip, h, now))
        if cur.rowcount != 1:
            evento(con, row["id"], "reservar", ip, "en_uso")
            con.execute("COMMIT")
            return 403, {"resultado": "rechazado", "motivo": "en_uso"}
        evento(con, row["id"], "reservar", ip, "reservado host=" + hostname)
        con.execute("COMMIT")
        return 200, {"resultado": "reservado", "token_id": row["id"], "reserva_id": reserva,
                     "vence_reserva": now + RESERVA_SEGUNDOS}
    except BaseException:
        con.execute("ROLLBACK")
        raise


def confirmar(con, token, reserva, ip):
    h = token_hash(token)
    con.execute("BEGIN IMMEDIATE")
    try:
        row = con.execute("SELECT * FROM tokens WHERE hash=?", (h,)).fetchone()
        if row is None:
            con.execute("COMMIT")
            return 403, {"resultado": "rechazado", "motivo": "invalido"}
        if row["estado"] == "consumido" and row["reserva_id"] == reserva:
            con.execute("COMMIT")
            return 200, {"resultado": "consumido", "token_id": row["id"]}
        # La reserva propia se confirma aunque haya pasado su plazo, mientras nadie la haya tomado.
        cur = con.execute(
            "UPDATE tokens SET estado='consumido', consumido=?, consumido_ip=? "
            "WHERE hash=? AND estado='reservado' AND reserva_id=?", (ahora_iso(), ip, h, reserva))
        res = "consumido" if cur.rowcount == 1 else "reserva"
        evento(con, row["id"], "confirmar", ip, res)
        con.execute("COMMIT")
        if res != "consumido":
            return 403, {"resultado": "rechazado", "motivo": "reserva"}
        return 200, {"resultado": "consumido", "token_id": row["id"]}
    except BaseException:
        con.execute("ROLLBACK")
        raise


def liberar(con, token, reserva, ip):
    h = token_hash(token)
    con.execute("BEGIN IMMEDIATE")
    try:
        row = con.execute("SELECT id FROM tokens WHERE hash=?", (h,)).fetchone()
        cur = con.execute(
            "UPDATE tokens SET estado='emitido', reserva_id=NULL, reserva_vence=NULL, reserva_host=NULL, "
            "reserva_ip=NULL WHERE hash=? AND estado='reservado' AND reserva_id=?", (h, reserva))
        res = "liberado" if cur.rowcount == 1 else "reserva"
        evento(con, row["id"] if row else None, "liberar", ip, res)
        con.execute("COMMIT")
        if res != "liberado":
            return 403, {"resultado": "rechazado", "motivo": "reserva"}
        return 200, {"resultado": "liberado"}
    except BaseException:
        con.execute("ROLLBACK")
        raise


# ------------------------------------------------------------------ HTTP
class Limitador:
    """Hasta LIMITE_POR_MINUTO pedidos por IP en una ventana de 60 s."""

    def __init__(self, limite):
        self.limite = limite
        self.lock = threading.Lock()
        self.pedidos = {}

    def permitir(self, ip):
        now = time.monotonic()
        with self.lock:
            lista = [t for t in self.pedidos.get(ip, []) if now - t < 60]
            ok = len(lista) < self.limite
            if ok:
                lista.append(now)
            self.pedidos[ip] = lista
            if len(self.pedidos) > 10000:
                self.pedidos = {k: v for k, v in self.pedidos.items() if v and now - v[-1] < 60}
            return ok


class Handler(BaseHTTPRequestHandler):
    server_version = "vpsarg-autorizacion"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def ip_cliente(self):
        peer = self.client_address[0]
        # Detrás de Caddy/nginx en el mismo servidor: la IP real es la última de X-Forwarded-For.
        if self.server.detras_de_proxy and ipaddress.ip_address(peer).is_loopback:
            xff = self.headers.get("X-Forwarded-For", "")
            if xff:
                cand = xff.split(",")[-1].strip()
                try:
                    return str(ipaddress.ip_address(cand))
                except ValueError:
                    pass
        return peer

    def responder(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_request(self, code="-", size="-"):
        # Nunca se registra el cuerpo (que lleva el token) ni una ruta desconocida (podría llevarlo).
        ruta = self.path if self.path in RUTAS else "(otra ruta)"
        sys.stderr.write("%s %s %s %s\n" % (self.ip_cliente(), self.command, ruta, code))

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.ip_cliente(), fmt % args))

    def do_GET(self):
        if self.path == "/v1/salud":
            self.responder(200, {"ok": True})
        else:
            self.responder(404, {"resultado": "error", "motivo": "ruta"})

    def do_POST(self):
        ip = self.ip_cliente()
        if self.path not in RUTAS[:3]:
            self.responder(404, {"resultado": "error", "motivo": "ruta"})
            return
        if not self.server.limitador.permitir(ip):
            self.responder(429, {"resultado": "error", "motivo": "demasiados_pedidos"})
            return
        try:
            largo = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            largo = -1
        if largo < 1 or largo > MAX_BODY:
            self.responder(400, {"resultado": "error", "motivo": "pedido"})
            return
        try:
            datos = json.loads(self.rfile.read(largo).decode("utf-8"))
            if not isinstance(datos, dict):
                raise ValueError
        except (ValueError, UnicodeDecodeError):
            self.responder(400, {"resultado": "error", "motivo": "pedido"})
            return
        token = datos.get("token")
        if not isinstance(token, str) or not TOKEN_RE.match(token):
            self.responder(403, {"resultado": "rechazado", "motivo": "invalido"})
            return
        con = conectar(self.server.db)
        try:
            if self.path == "/v1/reservar":
                host = datos.get("hostname")
                if not isinstance(host, str) or not HOST_RE.match(host):
                    host = "desconocido"
                code, resp = reservar(con, token, host, ip)
            else:
                reserva = datos.get("reserva_id")
                if not isinstance(reserva, str) or not RESERVA_RE.match(reserva):
                    self.responder(403, {"resultado": "rechazado", "motivo": "reserva"})
                    return
                fn = confirmar if self.path == "/v1/confirmar" else liberar
                code, resp = fn(con, token, reserva, ip)
        finally:
            con.close()
        self.responder(code, resp)


def servir(args):
    host, _, port = args.escuchar.rpartition(":")
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.db = args.db
    srv.detras_de_proxy = not args.sin_proxy
    srv.limitador = Limitador(args.limite)
    conectar(args.db).close()
    sys.stderr.write("vpsarg-autorizacion escuchando en %s (base %s)\n" % (args.escuchar, args.db))
    srv.serve_forever()


# ------------------------------------------------------------------ administración
def cmd_emitir(args):
    if not NOTA_RE.match(args.nota):
        sys.exit("NOTA no válida (letras, números, espacio y . _ @ -, hasta 60).")
    try:
        datetime.date.fromisoformat(args.vence)
    except ValueError:
        sys.exit("VENCE no válido (AAAA-MM-DD).")
    if args.vence < hoy():
        sys.exit("VENCE ya pasó.")
    token = "vpsarg_" + secrets.token_urlsafe(32)
    con = conectar(args.db)
    tid = args.id or ("t" + secrets.token_hex(6))
    if not ID_RE.match(tid):
        sys.exit("ID no válido.")
    try:
        con.execute("INSERT INTO tokens (id, hash, nota, vence, estado, creado) VALUES (?,?,?,?, 'emitido', ?)",
                    (tid, token_hash(token), args.nota, args.vence, ahora_iso()))
    except sqlite3.IntegrityError:
        sys.exit("Ya existe un token con ese ID.")
    evento(con, tid, "emitir", "local", "emitido")
    print("ID: %s  vence: %s  nota: %s" % (tid, args.vence, args.nota or "-"), file=sys.stderr)
    print("Token (se muestra una sola vez; no queda guardado en el servidor):", file=sys.stderr)
    print(token)


def fila(con, tid):
    row = con.execute("SELECT * FROM tokens WHERE id=?", (tid,)).fetchone()
    if row is None:
        sys.exit("No existe el token %s." % tid)
    return row


def cmd_listar(args):
    con = conectar(args.db)
    print("%-16s %-10s %-11s %-21s %s" % ("ID", "ESTADO", "VENCE", "RESERVA/CONSUMO", "NOTA"))
    for r in con.execute("SELECT * FROM tokens ORDER BY creado"):
        extra = r["consumido"] or (r["reserva_host"] or "-")
        print("%-16s %-10s %-11s %-21s %s" % (r["id"], r["estado"], r["vence"], extra, r["nota"]))


def cmd_ver(args):
    con = conectar(args.db)
    r = fila(con, args.id)
    for k in r.keys():
        if k != "hash":
            print("%-14s %s" % (k, r[k]))
    for e in con.execute("SELECT * FROM eventos WHERE token_id=? ORDER BY fecha", (args.id,)):
        print("  %s %-10s %-15s %s" % (e["fecha"], e["accion"], e["ip"] or "-", e["resultado"]))


def cmd_cambiar(args, accion):
    con = conectar(args.db)
    con.execute("BEGIN IMMEDIATE")
    r = fila(con, args.id)
    if accion == "revocar":
        if r["estado"] == "consumido":
            con.execute("ROLLBACK")
            sys.exit("El token ya se consumió; no se puede revocar.")
        con.execute("UPDATE tokens SET estado='revocado', revocado=? WHERE id=?", (ahora_iso(), args.id))
    elif accion == "liberar":
        if r["estado"] != "reservado":
            con.execute("ROLLBACK")
            sys.exit("El token no está reservado (estado: %s)." % r["estado"])
        con.execute("UPDATE tokens SET estado='emitido', reserva_id=NULL, reserva_vence=NULL, reserva_host=NULL, "
                    "reserva_ip=NULL WHERE id=?", (args.id,))
    elif accion == "confirmar":
        if r["estado"] != "reservado":
            con.execute("ROLLBACK")
            sys.exit("El token no está reservado (estado: %s)." % r["estado"])
        con.execute("UPDATE tokens SET estado='consumido', consumido=?, consumido_ip='manual' WHERE id=?",
                    (ahora_iso(), args.id))
    evento(con, args.id, accion, "local", "ok")
    con.execute("COMMIT")
    print("%s: %s" % (args.id, accion))


def main():
    p = argparse.ArgumentParser(description="VPS ARG QuickStart - servicio de autorización")
    p.add_argument("--db", default=os.environ.get("VPSARG_AUTORIZACION_DB", DB_DEFAULT))
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("emitir")
    e.add_argument("--vence", default=(datetime.date.today() + datetime.timedelta(days=30)).isoformat())
    e.add_argument("--nota", default="")
    e.add_argument("--id", default="")
    sub.add_parser("listar")
    for name in ("ver", "revocar", "liberar", "confirmar"):
        sub.add_parser(name).add_argument("id")
    s = sub.add_parser("servir")
    s.add_argument("--escuchar", default="127.0.0.1:8090")
    s.add_argument("--limite", type=int, default=LIMITE_POR_MINUTO)
    s.add_argument("--sin-proxy", action="store_true",
                   help="no confiar en X-Forwarded-For (sin Caddy/nginx delante)")
    args = p.parse_args()
    if args.cmd == "emitir":
        cmd_emitir(args)
    elif args.cmd == "listar":
        cmd_listar(args)
    elif args.cmd == "ver":
        cmd_ver(args)
    elif args.cmd in ("revocar", "liberar", "confirmar"):
        cmd_cambiar(args, args.cmd)
    elif args.cmd == "servir":
        servir(args)


if __name__ == "__main__":
    main()
