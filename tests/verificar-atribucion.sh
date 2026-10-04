#!/usr/bin/env bash
# VPS ARG QuickStart - etapa 3D, paso 1: ¿se puede atribuir el tráfico SSH a cada usuario?
# Para correr en la VPS real (laboratorio autorizado). No modifica sshd_config, PAM,
# el firewall, PDirect-C, UDPGW ni HCR, y no reinicia ningún servicio.
# Qué hace:
#   1. Muestra, solo lectura, qué entrega `ss -tinpe` para las sesiones SSH abiertas y a qué
#      usuario se atribuye cada una (las IP remotas se ocultan).
#   2. Prueba controlada: crea 2 cuentas temporales (vpsarg-atra, vpsarg-atrb; sin shell,
#      entran solo con una clave temporal), abre 3 conexiones SSH a 127.0.0.1 (directa y por
#      PDirect-C), pasa una cantidad conocida de bytes por cada una, a la vez, y compara con
#      los contadores que `ss` atribuye a cada usuario.
#   3. Borra las cuentas, las claves y los procesos de prueba, aunque algo falle.
# Resultado: ATRIBUCIÓN FIABLE o "SIN MEDICIÓN: no se pudo demostrar atribución fiable por usuario".
# Uso: sudo bash verificar-atribucion.sh   (la salida también queda en /root/)
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Usá sudo." >&2; exit 1; }
[[ -e /etc/vpsarg-laboratorio ]] || { echo "Solo en una VPS de laboratorio marcada con /etc/vpsarg-laboratorio." >&2; exit 1; }

OUTFILE="/root/verificacion-atribucion-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUTFILE") 2>&1
USERS_T=(vpsarg-atra vpsarg-atrb)
DIR=""
PIDS=()
FAILS=0
MB=1000000

ok()  { echo "PASA  $*"; }
bad() { echo "FALLA $*"; FAILS=$((FAILS + 1)); }

cleanup() {
  local p u uid
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 1
  for u in "${USERS_T[@]}"; do
    uid="$(id -u "$u" 2>/dev/null)" || continue
    pkill -TERM -u "$uid" 2>/dev/null
    for _ in $(seq 20); do pgrep -u "$uid" >/dev/null || break; ((_ == 4)) && systemctl stop "user@$uid.service" 2>/dev/null; sleep 0.5; done
    userdel "$u" 2>/dev/null || echo "AVISO: no se pudo borrar $u (borrala con: userdel $u)"
  done
  [[ -n "$DIR" ]] && rm -rf -- "$DIR"
  echo
  echo "Limpieza: cuentas temporales $(getent passwd "${USERS_T[@]}" >/dev/null && echo 'QUEDARON' || echo 'borradas'); archivos temporales borrados."
}
trap cleanup EXIT

PORT="$(sed -n 's/^SSH_PORT=\([0-9]*\)$/\1/p' /etc/vpsarg-pdirect.conf 2>/dev/null)"
PORT="${PORT:-22}"

echo "=== Sistema"
echo "Fecha: $(date -u '+%F %T UTC')"
echo "SO: $(. /etc/os-release; echo "$PRETTY_NAME") · núcleo $(uname -r)"
echo "ss: $(ss -V 2>&1 | head -1)"
echo "OpenSSH: $(ssh -V 2>&1)"
echo "Puerto SSH de destino: $PORT · PDirect-C: $(systemctl is-active pdirect-80 2>/dev/null) · HCR: $(systemctl is-active hcr-8880 2>/dev/null || true)"
echo "sshd: usepam=$(sshd -T 2>/dev/null | awk '$1=="usepam"{print $2}') pubkeyauthentication=$(sshd -T 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2}')"

# sockets: una línea por conexión SSH establecida en el puerto de sshd:
#   INODO USUARIO bytes_acked bytes_received PID:UID:COMANDO,...
# USUARIO = dueño (UID distinto de 0) de algún proceso que tiene el socket abierto; "?" si no hay.
sockets() {
  ss -Htinpe state established "( sport = :$PORT )" 2>/dev/null | awk '
    /^[^ \t]/ { if (s != "") print s, a + 0, r + 0; s = ""; a = 0; r = 0
                ino = ""; if (match($0, /ino:[0-9]+/)) ino = substr($0, RSTART + 4, RLENGTH - 4)
                pids = ""; line = $0
                while (match(line, /pid=[0-9]+/)) { pids = pids (pids == "" ? "" : ",") substr(line, RSTART + 4, RLENGTH - 4); line = substr(line, RSTART + RLENGTH) }
                s = ino " " (pids == "" ? "-" : pids); next }
    { if (match($0, /bytes_acked:[0-9]+/)) a = substr($0, RSTART + 12, RLENGTH - 12)
      if (match($0, /bytes_received:[0-9]+/)) r = substr($0, RSTART + 15, RLENGTH - 15) }
    END { if (s != "") print s, a + 0, r + 0 }' |
  while read -r ino pids acked recv; do
    local owner="?" desc="" p uid comm
    for p in ${pids//,/ }; do
      uid="$(awk '/^Uid:/{print $2}' "/proc/$p/status" 2>/dev/null)"
      comm="$(cat "/proc/$p/comm" 2>/dev/null)"
      desc="$desc${desc:+,}$p:${uid:-?}:${comm:-?}"
      [[ -n "$uid" && "$uid" != 0 ]] && owner="$(id -nu "$uid" 2>/dev/null || echo "uid$uid")"
    done
    echo "$ino $owner $acked $recv $desc"
  done
}

echo
echo "=== 1. Salida de ss para las sesiones SSH abiertas ahora (IP remotas ocultas)"
ss -Htinpe state established "( sport = :$PORT )" 2>/dev/null | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}:/IP:/g; s/\[[0-9a-f:]+\]:/[IPv6]:/g' | head -40
echo
echo "Atribución (INODO USUARIO descarga subida PID:UID:proceso):"
sockets | sed 's/^/  /'
echo "(Si conectaste tu app con una cuenta VPS ARG antes de correr esto, tiene que aparecer con su usuario.)"

echo
echo "=== 2. Prueba controlada"
for c in python3 ssh ssh-keygen useradd; do command -v "$c" >/dev/null || { bad "falta $c"; exit 1; }; done
for u in "${USERS_T[@]}"; do getent passwd "$u" >/dev/null && { bad "ya existe la cuenta $u"; USERS_T=(); exit 1; }; done
DIR="$(mktemp -d /run/vpsarg-atrib.XXXXXX)"; chmod 0755 "$DIR"
ssh-keygen -q -t ed25519 -N '' -C vpsarg-atrib -f "$DIR/clave" >/dev/null
for u in "${USERS_T[@]}"; do
  useradd -M -d "$DIR/$u" -s /usr/sbin/nologin "$u" || { bad "useradd $u"; exit 1; }
  install -d -m 0700 -o "$u" -g "$u" "$DIR/$u" "$DIR/$u/.ssh"
  install -m 0600 -o "$u" -g "$u" "$DIR/clave.pub" "$DIR/$u/.ssh/authorized_keys"
done

# Servidor local de bytes: "D n" envía n bytes; "U n" recibe n bytes y contesta OK.
cat > "$DIR/bytes.py" <<'EOF'
import socket, sys, threading
def serve(c):
    f = c.makefile("rb")
    cmd, n = f.readline().split(); n = int(n)
    if cmd == b"D":
        chunk = b"x" * 65536
        while n > 0:
            k = min(n, len(chunk)); c.sendall(chunk[:k]); n -= k
    else:
        while n > 0:
            d = f.read(min(n, 65536))
            if not d: break
            n -= len(d)
        c.sendall(b"OK\n")
    c.close()
if sys.argv[1] == "server":
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0)); s.listen(16); print(s.getsockname()[1], flush=True)
    while True:
        c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
else:
    port, cmd, n = int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    c = socket.create_connection(("127.0.0.1", port)); c.sendall(("%s %d\n" % (cmd, n)).encode())
    got = 0
    if cmd == "D":
        while True:
            d = c.recv(65536)
            if not d: break
            got += len(d)
    else:
        chunk = b"y" * 65536; left = n
        while left > 0:
            k = min(left, len(chunk)); c.sendall(chunk[:k]); left -= k
        got = n if c.recv(16).startswith(b"OK") else -1
    sys.exit(0 if got == n else 1)
EOF
cat > "$DIR/pd-proxy.py" <<'EOF'
import os, select, socket, sys
s = socket.create_connection(("127.0.0.1", 80))
s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n\r\n")
buf = b""
while buf.count(b"\r\n\r\n") < 2:
    d = s.recv(1)
    if not d:
        sys.exit(1)
    buf += d
while True:
    r, _, _ = select.select([0, s], [], [])
    if 0 in r:
        d = os.read(0, 65536)
        if not d:
            s.shutdown(socket.SHUT_WR)
        else:
            s.sendall(d)
    if s in r:
        d = s.recv(65536)
        if not d:
            break
        os.write(1, d)
EOF
python3 "$DIR/bytes.py" server > "$DIR/puerto" 2>/dev/null &
PIDS+=($!)
sleep 1
SRV="$(cat "$DIR/puerto")"
[[ "$SRV" =~ ^[0-9]+$ ]] || { bad "no arrancó el servidor de bytes local"; exit 1; }

OPTS=(-i "$DIR/clave" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -p "$PORT")
declare -A CPID
# conectar NOMBRE USUARIO VÍA PUERTO_LOCAL
conectar() {
  local px=(-o ProxyCommand=none)
  [[ "$3" == pdirect ]] && px=(-o "ProxyCommand=python3 $DIR/pd-proxy.py")
  ssh "${OPTS[@]}" "${px[@]}" -N -L "127.0.0.1:$4:127.0.0.1:$SRV" "$2@127.0.0.1" </dev/null >/dev/null 2>&1 &
  PIDS+=($!)
  CPID[$1]=$!
}
conectar A1 vpsarg-atra directo 19101
conectar A2 vpsarg-atra pdirect 19102
conectar B1 vpsarg-atrb pdirect 19103
for _ in $(seq 30); do
  [[ "$(sockets | awk '$2 ~ /^vpsarg-atr/' | wc -l)" == 3 ]] && break
  sleep 0.5
done
sockets | awk '$2 ~ /^vpsarg-atr/' > "$DIR/antes"
if [[ "$(wc -l < "$DIR/antes")" != 3 ]]; then
  bad "no se abrieron las 3 conexiones de prueba (¿claves públicas deshabilitadas o AllowUsers/AllowGroups?)"
  sockets | sed 's/^/  /'
  echo; echo "SIN MEDICIÓN: no se pudo demostrar atribución fiable por usuario"; exit 1
fi
echo "Conexiones de prueba (INODO USUARIO descarga subida PID:UID:proceso):"
sed 's/^/  /' "$DIR/antes"
grep -q " vpsarg-atra .*:sshd" "$DIR/antes" && grep -q " vpsarg-atrb .*:sshd" "$DIR/antes" \
  && ok "cada socket SSH lo tiene abierto un proceso sshd con el UID de su usuario" \
  || bad "algún socket no tiene un proceso sshd con el UID del usuario"
[[ "$(awk '$2=="vpsarg-atra"' "$DIR/antes" | wc -l)" == 2 && "$(awk '$2=="vpsarg-atrb"' "$DIR/antes" | wc -l)" == 1 ]] \
  && ok "2 sockets atribuidos a vpsarg-atra y 1 a vpsarg-atrb" || bad "la atribución de sockets no coincide (2 y 1)"
[[ "$(awk '$2=="?"' <(sockets) | wc -l)" == 0 ]] && ok "ningún socket SSH quedó sin usuario" || echo "AVISO: hay sockets SSH sin usuario: conexiones que todavía no se autenticaron o sesiones de root (no son cuentas VPS ARG)"

# Tráfico conocido, las 3 conexiones a la vez. Bytes distintos para que se note cualquier mezcla.
echo
echo "Pasando tráfico a la vez: A1 baja 30 MB y sube 7 MB (directo); A2 baja 11 MB y sube 3 MB (PDirect-C); B1 baja 19 MB y sube 13 MB (PDirect-C)."
declare -A EXP_D=([19101]=30 [19102]=11 [19103]=19) EXP_U=([19101]=7 [19102]=3 [19103]=13)
T=()
for lp in 19101 19102 19103; do
  python3 "$DIR/bytes.py" client "$lp" D $((EXP_D[$lp] * MB)) & T+=($!)
  python3 "$DIR/bytes.py" client "$lp" U $((EXP_U[$lp] * MB)) & T+=($!)
done
tfail=0
for p in "${T[@]}"; do wait "$p" || tfail=1; done
((tfail == 0)) && ok "todas las transferencias completas" || bad "alguna transferencia no se completó"
sleep 1
sockets | awk '$2 ~ /^vpsarg-atr/' > "$DIR/despues"

echo
echo "Resultado por socket (MB = 1 000 000 bytes):"
printf '  %-6s %-12s %12s %12s %12s %12s\n' CONEX USUARIO "DESC.REAL" "DESC.MEDIDA" "SUB.REAL" "SUB.MEDIDA"
declare -A UD UU
# Diferencia de contadores por socket; se suma por usuario.
for u in vpsarg-atra vpsarg-atrb; do
  dd_tot=0; du_tot=0
  while read -r ino owner acked recv _; do
    a0="$(awk -v i="$ino" '$1==i{print $3}' "$DIR/antes")"; r0="$(awk -v i="$ino" '$1==i{print $4}' "$DIR/antes")"
    [[ -n "$a0" ]] || { bad "socket $ino de $owner no existía antes"; continue; }
    dd=$((acked - a0)); du=$((recv - r0))
    echo "$u $ino $dd $du" >> "$DIR/deltas"
    dd_tot=$((dd_tot + dd)); du_tot=$((du_tot + du))
  done < <(awk -v u="$u" '$2==u' "$DIR/despues")
  UD[$u]=$dd_tot; UU[$u]=$du_tot
done
# Valor real esperado por socket, de mayor a menor descarga, comparado con lo medido ordenado igual.
check_socket() {  # USUARIO "esperados descarga (MB, orden desc)" "esperados subida (MB)"
  local u="$1" exp_d=($2) exp_u=($3) i=0 dd du lo hi
  while read -r _ _ dd du; do
    lo=$((exp_d[i] * MB)); hi=$((exp_d[i] * MB * 103 / 100 + 200000))
    printf '  %-6s %-12s %12s %12s %12s %12s\n' "#$((i + 1))" "$u" "$lo" "$dd" "$((exp_u[i] * MB))" "$du"
    if ((dd >= lo && dd <= hi)); then ok "$u socket $((i + 1)): descarga medida = real + $(( (dd - lo) * 10000 / lo )) diezmilésimos"; else bad "$u socket $((i + 1)): descarga $dd fuera de [$lo, $hi]"; fi
    lo=$((exp_u[i] * MB)); hi=$((exp_u[i] * MB * 103 / 100 + 200000))
    if ((du >= lo && du <= hi)); then ok "$u socket $((i + 1)): subida medida = real + $(( (du - lo) * 10000 / lo )) diezmilésimos"; else bad "$u socket $((i + 1)): subida $du fuera de [$lo, $hi]"; fi
    i=$((i + 1))
  done < <(awk -v u="$u" '$1==u' "$DIR/deltas" | sort -k3,3nr)
}
check_socket vpsarg-atra "30 11" "7 3"
check_socket vpsarg-atrb "19" "13"
echo "Total vpsarg-atra: descarga ${UD[vpsarg-atra]} B (real 41 MB), subida ${UU[vpsarg-atra]} B (real 10 MB)"
echo "Total vpsarg-atrb: descarga ${UD[vpsarg-atrb]} B (real 19 MB), subida ${UU[vpsarg-atrb]} B (real 13 MB)"

echo
echo "=== 3. Cierre"
kill "${CPID[A1]}" 2>/dev/null
for _ in $(seq 20); do [[ "$(sockets | awk '$2=="vpsarg-atra"' | wc -l)" == 1 ]] && break; sleep 0.5; done
[[ "$(sockets | awk '$2=="vpsarg-atra"' | wc -l)" == 1 ]] && ok "al cerrar la conexión directa de vpsarg-atra su socket desaparece y queda 1" \
  || bad "el socket de la conexión cerrada sigue apareciendo"

echo
if ((FAILS == 0)); then
  echo "ATRIBUCIÓN FIABLE: cada conexión SSH se atribuye a su usuario por el UID del proceso sshd que tiene el socket, y los contadores coinciden con el tráfico real."
else
  echo "SIN MEDICIÓN: no se pudo demostrar atribución fiable por usuario ($FAILS fallas)"
fi
echo "Salida guardada en $OUTFILE"
