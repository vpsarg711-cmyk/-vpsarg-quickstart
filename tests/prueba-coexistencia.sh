#!/usr/bin/env bash
# Coexistencia y persistencia de la instalación completa (PDirect-C, UDPGW, HCR, BHTTP,
# panel, AUTO y límite PAM), SOLO en un contenedor de laboratorio instalado con install.sh.
#   preparar: crea la cuenta coex (límite 1), activa el límite PAM y AUTO para root, y
#             comprueba todo funcionando a la vez.
#   despues:  después de reiniciar, comprueba que todo volvió solo y sigue funcionando;
#             al final deja AUTO y el límite como estaban y borra la cuenta.
# Usa tests/bhttp-cliente.py (cliente de laboratorio de BHTTP) y sshpass.
# Uso: sudo bash tests/prueba-coexistencia.sh preparar|despues
# shellcheck disable=SC2016
set -uo pipefail

[[ -e /.dockerenv ]] || { echo "Solo en el contenedor de laboratorio." >&2; exit 1; }
MODE="${1:?Uso: prueba-coexistencia.sh preparar|despues}"
CLIENT="$(cd "$(dirname "$0")" && pwd)/bhttp-cliente.py"
PW='Coex-Prueba.Clave'
OUT=/tmp/coex.out
STATE=/root/coex-estado
PASS=0
FAILS=0
CLIENTS=()
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
         -o ConnectTimeout=15 -o ServerAliveInterval=5)
via() {
  case "$1" in
    bhttp) echo "ProxyCommand=python3 $CLIENT 127.0.0.1 8001" ;;
    pdirect) echo "ProxyCommand=python3 /tmp/pd-proxy.py" ;;
    *) echo "ProxyCommand=none" ;;
  esac
}
run() { SSHPASS="$PW" timeout 40 sshpass -e ssh "${SSHOPTS[@]}" -o "$(via "$2")" "$1@127.0.0.1" "$3" </dev/null >"$OUT" 2>&1; }
conn() {
  SSHPASS="$PW" sshpass -e ssh "${SSHOPTS[@]}" -o "$(via "$2")" -N "$1@127.0.0.1" </dev/null >/dev/null 2>&1 &
  C=$!
  CLIENTS+=("$C")
}
accepted() { conn "$@"; sleep 6; kill -0 "$C" 2>/dev/null; }
rejected() {
  local rc=0
  SSHPASS="$PW" timeout 30 sshpass -e ssh "${SSHOPTS[@]}" -o "$(via "$2")" -N "$1@127.0.0.1" </dev/null >"$OUT" 2>&1 || rc=$?
  ((rc != 0 && rc != 124))
}
close_all() { local p; for p in "${CLIENTS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; CLIENTS=(); }
pdirect_ssh() {
  timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
    printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3
    for _ in 1 2 3 4 5 6 7 8; do IFS= read -r -t 4 l <&3 || exit 1; [[ "$l" == SSH-* ]] && exit 0; done; exit 1' 2>/dev/null
}
wait_up() {
  local _ u
  for _ in $(seq 60); do
    for u in pdirect-80 udpgw-7300 hcr-8880 bhttp-server bhttp-shim; do systemctl is-active --quiet "$u" || continue 2; done
    for u in 80 7300 8880 8001 18022; do listening "$u" || continue 2; done
    return 0
  done
  return 1
}

cat > /tmp/pd-proxy.py <<'EOF'
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

all_working() {
  local tag="$1"
  check "$tag: los 5 servicios activos y los 5 puertos en escucha" wait_up
  check "$tag: protocolos del panel: PDirect-C, UDPGW, HCR, BHTTP y SSH ACTIVO" \
    bash -c 'o="$(vpsarg protocolos)"; for p in "PDirect-C +ACTIVO +80 " "UDPGW +ACTIVO +7300 " "HCR +ACTIVO +8880 " "BHTTP +ACTIVO +8001 " "SSH +ACTIVO +22 "; do grep -qE "^$p" <<<"$o" || exit 1; done'
  check "$tag: PDirect-C llega a SSH" pdirect_ssh
  check "$tag: UDPGW acepta conexiones en 7300" timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/7300'
  check "$tag: HCR acepta conexiones en 8880" timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8880'
  check "$tag: HCR sin root apuntando a 127.0.0.1:22" \
    bash -c 'p=$(systemctl show -p MainPID --value hcr-8880); [[ "$(ps -o uid= -p $p | tr -d " ")" != 0 ]] && tr "\0" " " < /proc/$p/cmdline | grep -q -- "-target 127.0.0.1:22 "'
  check "$tag: límite PAM ACTIVO" bash -c 'vpsarg-usuarios control | grep -q "ACTIVO (las"'
  check "$tag: AUTO ON para root" bash -c 'vpsarg auto | grep -qx "AUTO: ON para root"'
  check "$tag: coex entra por BHTTP" accepted coex bhttp
  local first="$C"
  check "$tag: con el límite (1), coex no entra otra vez por PDirect-C" rejected coex pdirect
  check "$tag: ni directo" rejected coex directo
  check "$tag: la sesión por BHTTP sigue abierta" kill -0 "$first"
  close_all
  pkill -9 -f bhttp-cliente.py 2>/dev/null
  # BHTTP no tiene cierre: la sesión cortada se libera con -session-ttl (180 s) de bhttp-server.
  check "$tag: la sesión cortada se libera sola (hasta 240 s)" bash -c 'for _ in $(seq 240); do [[ "$(vpsarg-usuarios listar | awk '"'"'$1=="coex"{print $(NF-1)}'"'"')" == 0 ]] && exit 0; sleep 1; done; exit 1'
  run coex pdirect 'true'
  check "$tag: coex entra por PDirect-C cuando está libre" grep -q "not available" "$OUT"
  # PDirect-C puede tardar ~60 s en soltar la conexión a SSH (documentado).
  check "$tag: y la sesión se libera al salir (hasta 90 s)" bash -c 'for _ in $(seq 90); do [[ "$(vpsarg-usuarios listar | awk '"'"'$1=="coex"{print $(NF-1)}'"'"')" == 0 ]] && exit 0; sleep 1; done; exit 1'
  run coex bhttp 'true'
  check "$tag: coex entra por BHTTP cuando está libre" grep -q "not available" "$OUT"
  # BHTTP no avisa el cierre: sshd puede quedar esperando hasta -session-ttl (180 s).
  check "$tag: y la sesión se libera al salir (hasta 240 s)" bash -c 'for _ in $(seq 240); do [[ "$(vpsarg-usuarios listar | awk '"'"'$1=="coex"{print $(NF-1)}'"'"')" == 0 ]] && exit 0; sleep 1; done; exit 1'
  check "$tag: el panel abre y cierra" bash -c 'printf "0\n" | timeout 20 vpsarg 2>&1 | grep -q "\[ 1 \] PROTOCOLOS"'
}

case "$MODE" in
  preparar)
    command -v sshpass >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null; }
    { echo "control=$(vpsarg-usuarios control | grep -q 'ACTIVO (las' && echo on || echo off)"
      echo "auto=$(vpsarg auto | grep -q ON && echo on || echo off)"; } > "$STATE"
    echo "$PW" | vpsarg-usuarios crear coex 30 1 >/dev/null 2>&1
    vpsarg-usuarios control on >/dev/null 2>&1
    vpsarg auto on >/dev/null
    echo "### Todo a la vez, antes de reiniciar"
    all_working antes
    ;;
  despues)
    echo "### Después de reiniciar"
    all_working despues
    check "después: bhttp-server y bhttp-shim habilitados al arranque" \
      bash -c 'systemctl is-enabled --quiet bhttp-server && systemctl is-enabled --quiet bhttp-shim'
    grep -qx control=off "$STATE" && vpsarg-usuarios control off >/dev/null 2>&1
    grep -qx auto=off "$STATE" && vpsarg auto off >/dev/null
    vpsarg-usuarios eliminar coex >/dev/null 2>&1
    rm -f "$STATE"
    ;;
  *) echo "Uso: prueba-coexistencia.sh preparar|despues" >&2; exit 1 ;;
esac
pkill -f bhttp-cliente.py 2>/dev/null
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
