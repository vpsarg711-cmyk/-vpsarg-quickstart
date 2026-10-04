#!/usr/bin/env bash
# Pruebas de laboratorio de BHTTP (bhttp-server + bhttp-shim) y del comando vpsarg-bhttp.
# SOLO para un contenedor de laboratorio con QuickStart instalado con token (install.sh):
# instala sshpass, crea y borra cuentas de prueba, inicia un sshd extra en 127.0.0.1:2222,
# un servidor web temporal en 8002, activa y desactiva el límite PAM y AUTO, mata procesos
# de BHTTP para probar la recuperación y entra por SSH de verdad a través de BHTTP con
# tests/bhttp-cliente.py (cliente de laboratorio del protocolo, no una app real).
# Uso: sudo bash tests/prueba-bhttp.sh CARPETA_CON_bhttp-server_Y_bhttp-shim
# shellcheck disable=SC2016
set -uo pipefail

[[ -e /.dockerenv ]] || { echo "Solo en el contenedor de laboratorio." >&2; exit 1; }
BINDIR="${1:?Uso: sudo bash tests/prueba-bhttp.sh CARPETA_CON_LOS_BINARIOS}"
CLIENT="$(cd "$(dirname "$0")" && pwd)/bhttp-cliente.py"
PW='Bhttp-Prueba.Clave'
OUT=/tmp/bhttp.out
PASS=0
FAILS=0
CLIENTS=()

ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -q -- "$1" "$OUT"; }
pid_of() { systemctl show -p MainPID --value "$1"; }
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }
conf() { sed -n "s/^$1=//p" /etc/vpsarg-bhttp.conf; }
arg_of() { tr '\0' '\n' < "/proc/$(pid_of "$1")/cmdline" | grep -A1 -x -- "$2" | tail -n 1; }
# Las comprobaciones con bash -c también usan estas funciones.
export OUT
export -f listening conf has
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
         -o ConnectTimeout=15 -o ServerAliveInterval=5)
via() {
  case "$1" in
    bhttp) echo "ProxyCommand=python3 $CLIENT 127.0.0.1 $(conf BHTTP_PORT)" ;;
    bhttp-servidor) echo "ProxyCommand=python3 $CLIENT 127.0.0.1 $(conf BHTTP_INTERNAL_PORT)" ;;
    pdirect) echo "ProxyCommand=python3 /tmp/pd-proxy.py" ;;
    *) echo "ProxyCommand=none" ;;
  esac
}
# run USUARIO VÍA COMANDO: entra por SSH, ejecuta el comando y deja la salida en OUT.
run() { SSHPASS="$PW" timeout 40 sshpass -e ssh "${SSHOPTS[@]}" -o "$(via "$2")" "$1@127.0.0.1" "$3" </dev/null >"$OUT" 2>&1; }
# conn USUARIO VÍA: conexión ssh -N en segundo plano (PID en C).
conn() {
  SSHPASS="$PW" sshpass -e ssh "${SSHOPTS[@]}" -o "$(via "$2")" -N "$1@127.0.0.1" </dev/null >/dev/null 2>&1 &
  C=$!
  CLIENTS+=("$C")
}
alive() { kill -0 "$1" 2>/dev/null; }
accepted() { conn "$@"; sleep 6; alive "$C"; }
rejected() {
  local rc=0
  SSHPASS="$PW" timeout 30 sshpass -e ssh "${SSHOPTS[@]}" -o "$(via "$2")" -N "$1@127.0.0.1" </dev/null >"$OUT" 2>&1 || rc=$?
  ((rc != 0 && rc != 124))
}
close_all() {
  local p
  for p in "${CLIENTS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  CLIENTS=()
}
sessions_of() { vpsarg-usuarios listar | awk -v u="$1" '$1==u{print $(NF-1)}'; }
wait_sessions() {
  local _
  for _ in $(seq "${3:-30}"); do
    [[ "$(sessions_of "$1")" == "$2" ]] && return 0
    sleep 1
  done
  return 1
}
wait_active() {
  local _
  for _ in $(seq 20); do
    systemctl is-active --quiet bhttp-server && systemctl is-active --quiet bhttp-shim \
      && listening "$(conf BHTTP_PORT)" && return 0
    sleep 0.5
  done
  return 1
}
create() { echo "$PW" | vpsarg-usuarios crear "$@" >/dev/null 2>&1; }
panel() { printf "%b" "$1" | timeout 60 vpsarg > "$OUT" 2>&1; }
sums() {
  sha256sum /etc/ssh/sshd_config /etc/shells /etc/vpsarg-pdirect.conf /etc/vpsarg-hcr.conf \
    /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
    /etc/systemd/system/hcr-8880.service /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw \
    /usr/local/lib/vpsarg/hcr-server
  find /etc/ssh/sshd_config.d -type f -exec sha256sum {} + 2>/dev/null
}

echo "### Preparación"
if ! command -v sshpass >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass openssh-client >/dev/null
fi
check "sshpass disponible (solo para la prueba)" command -v sshpass
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
vpsarg-usuarios control off >/dev/null 2>&1
create bhuno 30 1
create bhdos 30 2
# Las cuentas VPS ARG no tienen shell (nologin): para ejecutar comandos por el túnel
# se usa una cuenta de sistema común de la prueba, con bash.
useradd -m -s /bin/bash bhshell 2>/dev/null; echo "bhshell:$PW" | chpasswd
# Cuenta VPS ARG autenticada: sshd la deja entrar y nologin responde "not available".
auth_ok() { has "This account is currently not available"; }
mkdir -p /run/sshd
/usr/sbin/sshd -p 2222 -o PidFile=/run/sshd-2222.pid
SUMS0="$(sums)"
PD_PID0="$(pid_of pdirect-80)"
UG_PID0="$(pid_of udpgw-7300)"
HCR_PID0="$(pid_of hcr-8880)"
SSH_PID0="$(pid_of ssh)"

# systemd no puede dar más archivos abiertos que el máximo del sistema (en Docker suele ser menor).
NOFILE="$(awk '/^Max open files/{print $5}' /proc/1/limits)"; ((NOFILE > 65536)) && NOFILE=65536
echo "### 1. Instalación (hecha por install.sh)"
check "unidades bhttp-server y bhttp-shim de VPS ARG" \
  bash -c 'for u in bhttp-server bhttp-shim; do grep -qx "# VPS ARG QuickStart - BHTTP" /etc/systemd/system/$u.service || exit 1; done'
check "ambas habilitadas al arranque" bash -c 'systemctl is-enabled --quiet bhttp-server && systemctl is-enabled --quiet bhttp-shim'
check "configuración: externo 8001, interno 18022, SSH 22" \
  bash -c '[[ "$(sed -n "s/^BHTTP_PORT=//p;s/^BHTTP_INTERNAL_PORT=//p;s/^BHTTP_SSH_PORT=//p" /etc/vpsarg-bhttp.conf | tr "\n" " ")" == "8001 18022 22 " ]]'
check "binarios instalados iguales a los entregados (sha256)" \
  bash -c 'cmp -s /usr/local/lib/vpsarg/bhttp-server '"$BINDIR"'/bhttp-server && cmp -s /usr/local/lib/vpsarg/bhttp-shim '"$BINDIR"'/bhttp-shim'
check "binarios root:root 0755" bash -c '[[ "$(stat -c "%U %a" /usr/local/lib/vpsarg/bhttp-server /usr/local/lib/vpsarg/bhttp-shim | sort -u)" == "root 755" ]]'
check "registrados en vpsarg-servicios.conf (una vez cada uno)" \
  bash -c '[[ $(grep -cx bhttp-server /etc/vpsarg-servicios.conf) == 1 && $(grep -cx bhttp-shim /etc/vpsarg-servicios.conf) == 1 ]]'
check "versión SuperFlash 2.4.1" bash -c '/usr/local/lib/vpsarg/bhttp-server -version | grep -q "2.4.1-btun-compat-keepalive"'
check "autoprueba del protocolo del servidor" bash -c '/usr/local/lib/vpsarg/bhttp-server -self-test | grep -q BHTTP_SELF_TEST_PASS'

echo "### 2-3. Arquitectura"
check "amd64: el instalado es el shim amd64 entregado" \
  bash -c '[[ "$(uname -m)" == x86_64 && "$(sha256sum /usr/local/lib/vpsarg/bhttp-shim | cut -d" " -f1)" == f4cf6c183a48036519400cf3e8f5625d32248fca6d43d31b6c8401e1e2646d4c ]]'
check "arm64: hashes del servidor y del shim arm64 fijados en vpsarg-bhttp" \
  bash -c 'grep -q 6154c82038496e56973064cd5166642de17313b7f11217991bef9f8805c85b5f /usr/local/sbin/vpsarg-bhttp && grep -q 17b3fafeeb52bdd0a58aa22d38ac3d7bd1ef92d861b1e5c2d9f0cad8c1a518ad /usr/local/sbin/vpsarg-bhttp'
echo "(arm64 no se ejecuta: no hay laboratorio arm64; HCR es solo x86_64 y install.sh se detiene en arm64)"

echo "### 4. Servicio bhttp-server"
SP="$(pid_of bhttp-server)"
check "activo" systemctl is-active --quiet bhttp-server
check "sin root (usuario $(ps -o user= -p "$SP"))" test "$(ps -o uid= -p "$SP" | tr -d ' ')" != 0
check "sin capacidades efectivas" test "$(awk '/CapEff/{print $2}' "/proc/$SP/status")" = 0000000000000000
check "NoNewPrivileges" test "$(awk '/NoNewPrivs/{print $2}' "/proc/$SP/status")" = 1
check "LimitNOFILE 65536 (efectivo: $NOFILE, el máximo del sistema)" bash -c "[[ \$(systemctl show -p LimitNOFILE --value bhttp-server) == 65536 ]] && grep '^Max open files' /proc/$SP/limits | grep -q '$NOFILE *$NOFILE'"
check "Restart=on-failure" test "$(systemctl show -p Restart --value bhttp-server)" = on-failure

echo "### 5. Servicio bhttp-shim"
HP="$(pid_of bhttp-shim)"
check "activo" systemctl is-active --quiet bhttp-shim
check "sin root (usuario $(ps -o user= -p "$HP"))" test "$(ps -o uid= -p "$HP" | tr -d ' ')" != 0
check "sin capacidades efectivas" test "$(awk '/CapEff/{print $2}' "/proc/$HP/status")" = 0000000000000000
check "NoNewPrivileges" test "$(awk '/NoNewPrivs/{print $2}' "/proc/$HP/status")" = 1
check "LimitNOFILE 65536 (efectivo: $NOFILE, el máximo del sistema)" bash -c "[[ \$(systemctl show -p LimitNOFILE --value bhttp-shim) == 65536 ]] && grep '^Max open files' /proc/$HP/limits | grep -q '$NOFILE *$NOFILE'"
check "Restart=on-failure" test "$(systemctl show -p Restart --value bhttp-shim)" = on-failure
check "apunta a 127.0.0.1:18022" test "$(arg_of bhttp-shim -backend)" = 127.0.0.1:18022

echo "### 6-7. Puertos externo e interno"
IP="$(hostname -I | awk '{print $1}')"
check "externo: escucha en 0.0.0.0:8001 (bhttp-shim)" bash -c "ss -Hltnp 'sport = :8001' | grep -q '0.0.0.0:8001.*pid=$HP,'"
check "externo: responde desde la IP del servidor ($IP)" timeout 3 bash -c "exec 3<>/dev/tcp/$IP/8001"
check "interno: escucha solo en 127.0.0.1:18022 (bhttp-server)" \
  bash -c "[[ \$(ss -Hltnp 'sport = :18022' | wc -l) == 1 ]] && ss -Hltnp 'sport = :18022' | grep -q '127.0.0.1:18022.*pid=$SP,'"
check "interno: no responde desde la IP del servidor" bash -c "! timeout 3 bash -c 'exec 3<>/dev/tcp/$IP/18022' 2>/dev/null"

echo "### 8. Conexión con SSH"
run bhshell bhttp 'echo MARCA-$(whoami)'
check "SSH real por BHTTP (8001 -> 18022 -> 22): ejecuta un comando" has "MARCA-bhshell"
run bhshell bhttp-servidor 'echo MARCA-$(whoami)'
check "SSH real directo al servidor interno (18022)" has "MARCA-bhshell"
run bhuno bhttp 'true'
check "cuenta VPS ARG (bhuno, sin shell) se autentica por BHTTP" auth_ok
run bhshell bhttp 'head -c 5000000 /dev/zero | sha256sum'
check "transfiere 5 MB sin errores" has "$(head -c 5000000 /dev/zero | sha256sum | cut -d' ' -f1)"
wrong_password() { ! SSHPASS=otra timeout 30 sshpass -e ssh "${SSHOPTS[@]}" -o "$(via bhttp)" bhuno@127.0.0.1 true </dev/null >/dev/null 2>&1; }
check "contraseña equivocada: se rechaza" wrong_password

echo "### 9. Reinicio"
check "vpsarg-bhttp restart" bash -c 'vpsarg-bhttp restart > '"$OUT"' 2>&1'
check "PIDs nuevos tras reiniciar" bash -c "[[ \$(systemctl show -p MainPID --value bhttp-server) != $SP && \$(systemctl show -p MainPID --value bhttp-shim) != $HP ]]"
run bhshell bhttp 'echo MARCA-OK'
check "SSH por BHTTP después de reiniciar" has "MARCA-OK"

echo "### 10. Recuperación después de una caída"
P="$(pid_of bhttp-shim)"; kill -9 "$P"
check "bhttp-shim muerto (kill -9) vuelve solo" bash -c "sleep 4; [[ \$(systemctl show -p MainPID --value bhttp-shim) != $P ]] && systemctl is-active --quiet bhttp-shim"
P="$(pid_of bhttp-server)"; kill -9 "$P"
check "bhttp-server muerto (kill -9) vuelve solo" bash -c "sleep 4; [[ \$(systemctl show -p MainPID --value bhttp-server) != $P ]] && systemctl is-active --quiet bhttp-server"
run bhshell bhttp 'echo MARCA-OK'
check "SSH por BHTTP después de las caídas" has "MARCA-OK"

echo "### 11. Conflicto de puerto"
python3 -m http.server 8002 --bind 0.0.0.0 >/dev/null 2>&1 &
WEB=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do listening 8002 && break; sleep 0.5; done
check "rechaza 8002 ocupado por otro programa" bash -c '! vpsarg-bhttp puerto 8002 >/dev/null 2>&1'
check "no detuvo el programa del 8002" kill -0 "$WEB"
check "verificar (instalación) también lo rechaza sin cambiar nada" \
  bash -c 'S1=$(sha256sum /etc/vpsarg-bhttp.conf); ! vpsarg-bhttp verificar --desde '"$BINDIR"' --puerto 8002 >/dev/null 2>&1 && [[ "$(sha256sum /etc/vpsarg-bhttp.conf)" == "$S1" ]]'
kill "$WEB"
for p in 80 7300 8880 22 18022 2222 1000; do
  check "rechaza el puerto $p" bash -c "! vpsarg-bhttp puerto $p >/dev/null 2>&1"
done
check "sigue en 8001 después de los rechazos" bash -c '[[ "$(conf BHTTP_PORT)" == 8001 ]] && listening 8001'
check "HCR no puede tomar el puerto de BHTTP (aunque esté detenido)" \
  bash -c 'vpsarg-bhttp off >/dev/null; ! vpsarg-hcr puerto 8001 >/dev/null 2>&1; r=$?; vpsarg-bhttp on >/dev/null; exit $r'

echo "### Cambiar el puerto externo"
check "puerto: muestra 8001" bash -c 'vpsarg-bhttp puerto | grep -q "TCP 8001"'
check "cambiar 8001 -> 8011" vpsarg-bhttp puerto 8011
check "escucha en 8011 y ya no en 8001" bash -c 'listening 8011 && ! listening 8001'
run bhshell bhttp 'echo MARCA-8011'
check "SSH por BHTTP en 8011" has "MARCA-8011"
check "volver a 8001" vpsarg-bhttp puerto 8001
check "escucha otra vez en 8001" listening 8001

echo "### Comando vpsarg-bhttp"
vpsarg-bhttp status > "$OUT" 2>&1
check "status: ambos servicios, puertos y ACTIVO" bash -c 'grep -q "^bhttp-server *active" '"$OUT"' && grep -q "^bhttp-shim *active" '"$OUT"' && grep -q "Puerto externo:  TCP 8001" '"$OUT"' && grep -q "Puerto interno:  127.0.0.1:18022" '"$OUT"' && grep -q "BHTTP: ACTIVO" '"$OUT"''
check "off" bash -c 'vpsarg-bhttp off > '"$OUT"' 2>&1'
check "off: detenido, no escucha y no arranca al reiniciar" \
  bash -c '! systemctl is-active --quiet bhttp-server && ! systemctl is-active --quiet bhttp-shim && ! listening 8001 && ! systemctl is-enabled --quiet bhttp-server && ! systemctl is-enabled --quiet bhttp-shim'
check "status: INACTIVO" bash -c 'vpsarg-bhttp status | grep -q "BHTTP: INACTIVO"'
check "on" bash -c 'vpsarg-bhttp on > '"$OUT"' 2>&1'
check "on: activo, escucha y arranca al reiniciar" \
  bash -c 'systemctl is-active --quiet bhttp-server && systemctl is-active --quiet bhttp-shim && [[ -n "$(ss -Hltn "sport = :8001")" ]] && systemctl is-enabled --quiet bhttp-server && systemctl is-enabled --quiet bhttp-shim'
vpsarg-bhttp logs 20 > "$OUT" 2>&1
check "logs: muestra el registro de ambos servicios" bash -c 'grep -q "bhttp-server" '"$OUT"' && grep -q "bhttp-shim" '"$OUT"''
check "logs: rechaza una cantidad inválida" bash -c '! vpsarg-bhttp logs "1;id" >/dev/null 2>&1'
vpsarg-bhttp recursos > "$OUT" 2>&1
check "recursos: PID, CPU, RAM, tiempo activo y archivos de ambos" \
  bash -c 'grep -q "^SERVICIO *PID *CPU% *MEM% *RSS(kB) *ACTIVO *ARCHIVOS" '"$OUT"' && grep -q "^bhttp-server *$(systemctl show -p MainPID --value bhttp-server) " '"$OUT"' && grep -q "^bhttp-shim *$(systemctl show -p MainPID --value bhttp-shim) " '"$OUT"''
check "sin sudo se niega" bash -c '! setpriv --reuid=65534 --regid=65534 --clear-groups /usr/local/sbin/vpsarg-bhttp status >/dev/null 2>&1'
check "acción desconocida falla" bash -c '! vpsarg-bhttp borrar >/dev/null 2>&1'

echo "### 12. Usuarios VPS ARG, vencimiento y suspensión por BHTTP"
create bhvence 30 1
chage -E "$(( $(date +%s) / 86400 ))" bhvence   # simula que hoy es el día del vencimiento
run bhvence bhttp 'echo MARCA-VENCIDA'
check "cuenta vencida hoy: no entra por BHTTP" bash -c '! grep -q "not available" '"$OUT"''
vpsarg-usuarios renovar bhvence 10 >/dev/null 2>&1
run bhvence bhttp 'echo MARCA-RENOVADA'
check "renovada: entra por BHTTP" auth_ok
vpsarg-usuarios suspender bhvence >/dev/null 2>&1
run bhvence bhttp 'echo MARCA-SUSP'
check "suspendida: no entra por BHTTP" bash -c '! grep -q "not available" '"$OUT"''
vpsarg-usuarios eliminar bhvence >/dev/null 2>&1

echo "### 13. Límite PAM por BHTTP"
check "control on" bash -c 'vpsarg-usuarios control on >/dev/null 2>&1'
check "bhuno (límite 1): 1.ª conexión por BHTTP entra" accepted bhuno bhttp
FIRST="$C"
check "bhuno: la sesión por BHTTP cuenta (1)" wait_sessions bhuno 1
check "bhuno: 2.ª conexión por BHTTP se rechaza" rejected bhuno bhttp
check "bhuno: 2.ª conexión por PDirect-C también se rechaza" rejected bhuno pdirect
check "bhuno: la 1.ª sigue abierta" alive "$FIRST"
check "bhdos (límite 2): 1.ª por BHTTP entra" accepted bhdos bhttp
D1="$C"
check "bhdos: 2.ª por PDirect-C entra" accepted bhdos pdirect
check "bhdos: ambas siguen abiertas" bash -c "kill -0 $D1 && kill -0 $C"
check "bhdos: la 3.ª (directa) se rechaza" rejected bhdos directo
# BHTTP no tiene mensaje de cierre: si el cliente se corta (ssh y el cliente BHTTP mueren
# sin despedirse), bhttp-server mantiene la conexión a SSH hasta su -session-ttl (180 s).
# Se mide sin modificar BHTTP.
pkill -9 -f "bhttp-cliente.py 127.0.0.1 8001"; for p in "${CLIENTS[@]}"; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; CLIENTS=()
T0=$(date +%s)
wait_sessions bhuno 0 240 >/dev/null; wait_sessions bhdos 0 60 >/dev/null
echo "(clientes cortados: las sesiones por BHTTP se liberaron a los $(( $(date +%s) - T0 )) s; -session-ttl de bhttp-server = 180 s)"
both_free() { wait_sessions bhuno 0 1 && wait_sessions bhdos 0 1; }
check "clientes cortados: las sesiones se liberan solas (hasta 240 s)" both_free
# Cierre ordenado: la sesión SSH termina (nologin sale) y sshd cierra la conexión.
run bhuno bhttp 'true'
check "cierre ordenado: bhuno entra por BHTTP y sale" auth_ok
T0=$(date +%s)
wait_sessions bhuno 0 240 >/dev/null
echo "(cierre ordenado: la sesión por BHTTP se liberó a los $(( $(date +%s) - T0 )) s)"
check "cierre ordenado: la sesión se libera (hasta 240 s)" wait_sessions bhuno 0 1
check "control off" bash -c 'vpsarg-usuarios control off >/dev/null 2>&1'

echo "### 14. AUTO por BHTTP"
rm -f /tmp/bh-key /tmp/bh-key.pub
ssh-keygen -q -t ed25519 -N '' -f /tmp/bh-key
install -d -m 0700 /root/.ssh
cp -p /root/.ssh/authorized_keys /tmp/bh-authkeys 2>/dev/null || true
cat /tmp/bh-key.pub >> /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
AUTO_WAS="$(vpsarg auto)"
vpsarg auto on >/dev/null
printf '0\necho MAR""CA_AUTO\nexit\n' | timeout 60 script -qec "ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i /tmp/bh-key -o '$(via bhttp)' root@127.0.0.1" /dev/null > "$OUT" 2>&1
check "AUTO: el login de root por BHTTP abre el panel" grep -q "\[ 1 \] PROTOCOLOS" "$OUT"
check "AUTO: al salir del panel sigue la consola" grep -q "MARCA_AUTO" "$OUT"
[[ "$AUTO_WAS" == *OFF* ]] && vpsarg auto off >/dev/null
if [[ -e /tmp/bh-authkeys ]]; then cp -p /tmp/bh-authkeys /root/.ssh/authorized_keys; else rm -f /root/.ssh/authorized_keys; fi

echo "### 15. Panel"
check "protocolos: BHTTP ACTIVO 8001 con el PID del adaptador" \
  bash -c 'vpsarg protocolos | grep -qE "^BHTTP +ACTIVO +8001 +$(systemctl show -p MainPID --value bhttp-shim)$"'
check "protocolos: HCR ACTIVO 8880" bash -c 'vpsarg protocolos | grep -qE "^HCR +ACTIVO +8880 "'
check "estado: servidor y adaptador de BHTTP" bash -c 'vpsarg estado | grep -q "^BHTTP servidor .*18022" && vpsarg estado | grep -q "^BHTTP adaptador .*8001"'
panel "0\n"
check "menú principal: BHTTP en la línea de estado" grep -q "BHTTP ● ACTIVO" "$OUT"
panel "1\n4\n0\n0\n0\n"
check "ficha BHTTP: puerto, interno y destino" bash -c 'grep -q "PROTOCOLOS › BHTTP" '"$OUT"' && grep -q "Puerto: *TCP 8001" '"$OUT"' && grep -q "Interno: *127.0.0.1:18022" '"$OUT"' && grep -q "Destino: *127.0.0.1:22" '"$OUT"''
panel "1\n4\n2\nn\n\n0\n0\n0\n"
check "panel: responder n a desactivar no cambia nada" systemctl is-active --quiet bhttp-shim
panel "1\n4\n2\ns\n\n0\n0\n0\n"
check "panel: desactivar" bash -c '! systemctl is-active --quiet bhttp-shim && ! systemctl is-enabled --quiet bhttp-shim'
check "panel: BHTTP DETENIDO" bash -c 'vpsarg protocolos | grep -qE "^BHTTP +DETENIDO +8001 +-$"'
panel "1\n4\n1\n\n0\n0\n0\n"
check "panel: activar" bash -c 'systemctl is-active --quiet bhttp-shim && systemctl is-enabled --quiet bhttp-shim'
panel "1\n4\n4\n8012\ns\n\n0\n0\n0\n"
check "panel: cambiar el puerto a 8012" bash -c 'listening 8012 && ! listening 8001'
panel "1\n4\n4\n80\ns\n\n0\n0\n0\n"
check "panel: el puerto 80 se rechaza y queda en 8012" bash -c 'grep -qx BHTTP_PORT=8012 /etc/vpsarg-bhttp.conf'
panel "1\n4\n4\n8001\ns\n\n0\n0\n0\n"
check "panel: volver a 8001" listening 8001
panel "1\n4\n3\ns\n\n0\n0\n0\n"
check "panel: reiniciar" bash -c 'journalctl -t vpsarg-panel -o cat | grep -q "accion=reiniciar servicio=bhttp resultado=ok"'
check "registro del panel: on, off y puerto" \
  bash -c 'j="$(journalctl -t vpsarg-panel -o cat)"; grep -q "accion=off servicio=bhttp resultado=ok" <<<"$j" && grep -q "accion=on servicio=bhttp resultado=ok" <<<"$j" && grep -q "accion=puerto-bhttp valor=8012 resultado=ok" <<<"$j" && grep -q "accion=puerto-bhttp valor=80 resultado=error" <<<"$j"'

echo "### 16-18. Coexistencia: todos los protocolos a la vez"
check "bhdos entra por BHTTP" accepted bhdos bhttp
A1="$C"
check "bhdos entra a la vez por PDirect-C" accepted bhdos pdirect
check "bhdos conectado a la vez por BHTTP y por PDirect-C" bash -c "kill -0 $A1 && kill -0 $C"
check "HCR escucha en 8880 mientras tanto" listening 8880
check "UDPGW escucha en 7300 mientras tanto" listening 7300
check "conexión al 7300 (UDPGW) aceptada mientras tanto" timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/7300'
close_all
check "PDirect-C, UDPGW y HCR no se reiniciaron por BHTTP" \
  bash -c "[[ \$(systemctl show -p MainPID --value pdirect-80) == $PD_PID0 && \$(systemctl show -p MainPID --value udpgw-7300) == $UG_PID0 && \$(systemctl show -p MainPID --value hcr-8880) == $HCR_PID0 ]]"
check "SSH no se reinició" test "$(pid_of ssh)" = "$SSH_PID0"

echo "### Destino SSH junto con PDirect-C y HCR (vpsarg-puertos puerto-ssh)"
check "puerto-ssh 2222" bash -c 'vpsarg-puertos puerto-ssh 2222 > '"$OUT"' 2>&1'
check "BHTTP apunta a 127.0.0.1:2222" bash -c '[[ "$(conf BHTTP_SSH_PORT)" == 2222 ]] && [[ "$(tr "\0" "\n" < /proc/$(systemctl show -p MainPID --value bhttp-server)/cmdline | grep -A1 -x -- -backend-port | tail -n 1)" == 2222 ]]'
run bhshell bhttp 'echo MARCA-2222'
check "SSH por BHTTP llega al sshd de 2222" has "MARCA-2222"
check "puerto-ssh 22 (volver)" bash -c 'vpsarg-puertos puerto-ssh 22 > '"$OUT"' 2>&1'
check "BHTTP otra vez en 22" bash -c '[[ "$(conf BHTTP_SSH_PORT)" == 22 ]]'
BIN=/usr/local/lib/vpsarg/bhttp-server
mv "$BIN" "$BIN.real"
cat > "$BIN" <<'EOF'
#!/bin/bash
# Binario de prueba: falla solo con destino 2222.
case "$*" in *"-backend-port 2222"*) exit 1 ;; esac
exec /usr/local/lib/vpsarg/bhttp-server.real "$@"
EOF
chmod 0755 "$BIN"
vpsarg-bhttp restart >/dev/null 2>&1
check "puerto-ssh 2222 falla porque BHTTP no arranca" bash -c '! vpsarg-puertos puerto-ssh 2222 > '"$OUT"' 2>&1'
check "informa que restauró los tres" has "se restauraron PDirect-C (22), HCR (22) y BHTTP (22)"
check "PDirect-C, HCR y BHTTP otra vez en 22" \
  bash -c 'grep -qx SSH_PORT=22 /etc/vpsarg-pdirect.conf && grep -qx HCR_SSH_PORT=22 /etc/vpsarg-hcr.conf && grep -qx BHTTP_SSH_PORT=22 /etc/vpsarg-bhttp.conf'
mv -f "$BIN.real" "$BIN"
vpsarg-bhttp restart >/dev/null 2>&1
check "BHTTP activo después de la reversión" wait_active
run bhshell bhttp 'echo MARCA-OK'
check "SSH por BHTTP después de la reversión" has "MARCA-OK"

echo "### 19. Desinstalación"
UG1="$(pid_of udpgw-7300)"; PD1="$(pid_of pdirect-80)"; HC1="$(pid_of hcr-8880)"
check "desinstalar" bash -c 'vpsarg-bhttp desinstalar > '"$OUT"' 2>&1'
check "sin unidades, binarios ni configuración" \
  bash -c '! test -e /etc/systemd/system/bhttp-server.service && ! test -e /etc/systemd/system/bhttp-shim.service && ! test -e /usr/local/lib/vpsarg/bhttp-server && ! test -e /usr/local/lib/vpsarg/bhttp-shim && ! test -e /etc/vpsarg-bhttp.conf'
check "sin líneas en vpsarg-servicios.conf" bash -c '! grep -qx "bhttp-server\|bhttp-shim" /etc/vpsarg-servicios.conf'
check "no escucha en 8001 ni en 18022" bash -c '! listening 8001 && ! listening 18022'
check "PDirect-C, UDPGW y HCR no se reiniciaron" bash -c "[[ \$(systemctl show -p MainPID --value pdirect-80) == $PD1 && \$(systemctl show -p MainPID --value udpgw-7300) == $UG1 && \$(systemctl show -p MainPID --value hcr-8880) == $HC1 ]]"
check "panel: BHTTP NO INSTALADO" bash -c 'vpsarg protocolos | grep -qE "^BHTTP +NO INSTALADO +- +-$"'
check "desinstalar otra vez no falla" bash -c 'vpsarg-bhttp desinstalar | grep -q "no está instalado"'
check "status sin BHTTP lo informa" bash -c 'vpsarg-bhttp status 2>&1 | grep -q "no está instalado"'

echo "### 20. Reinstalación"
mv /etc/vpsarg/instalacion /etc/vpsarg/instalacion.prueba
check "instalar se niega fuera de una instalación con token" \
  bash -c 'vpsarg-bhttp instalar 2>&1 | grep -q "BHTTP se instala con install.sh y un token" && ! test -e /etc/vpsarg-bhttp.conf'
mv /etc/vpsarg/instalacion.prueba /etc/vpsarg/instalacion
check "rechaza un binario modificado" \
  bash -c 'rm -rf /tmp/bh-mod; cp -r '"$BINDIR"' /tmp/bh-mod; printf x >> /tmp/bh-mod/bhttp-shim; ! vpsarg-bhttp instalar --desde /tmp/bh-mod > '"$OUT"' 2>&1 && grep -q "sha256 de bhttp-shim no coincide" '"$OUT"' && ! test -e /etc/vpsarg-bhttp.conf'
check "rechaza si falta un binario" \
  bash -c 'rm -f /tmp/bh-mod/bhttp-shim; ! vpsarg-bhttp instalar --desde /tmp/bh-mod > '"$OUT"' 2>&1 && grep -q "BHTTP requerido pero falta bhttp-shim" '"$OUT"''
check "reinstalar descargando y verificando (SHA256SUMS.txt + hashes fijos)" bash -c 'vpsarg-bhttp instalar > '"$OUT"' 2>&1'
check "informó la verificación de los binarios" has "binarios de BHTTP v2.4.1-btun-compat-keepalive (amd64) verificados"
check "activo otra vez en 8001 -> 18022 -> 22" bash -c 'systemctl is-active --quiet bhttp-server && systemctl is-active --quiet bhttp-shim && [[ -n "$(ss -Hltn "sport = :8001")" ]]'
run bhshell bhttp 'echo MARCA-REINST'
check "SSH por BHTTP después de reinstalar" has "MARCA-REINST"
check "reinstalar encima no duplica" bash -c 'vpsarg-bhttp instalar --desde '"$BINDIR"' >/dev/null 2>&1 && [[ $(grep -cx bhttp-shim /etc/vpsarg-servicios.conf) == 1 && $(systemctl list-unit-files --no-legend "bhttp-*" | wc -l) == 2 ]]'
check "con una instalación ajena (bhttp-install.sh) se niega sin tocarla" \
  bash -c 'vpsarg-bhttp desinstalar >/dev/null; printf "[Service]\nExecStart=/bin/true\n" > /etc/systemd/system/bhttp-server.service; S1=$(sha256sum /etc/systemd/system/bhttp-server.service); ! vpsarg-bhttp instalar --desde '"$BINDIR"' > '"$OUT"' 2>&1; r=$?; grep -q "bhttp-install.sh desinstalar" '"$OUT"' && [[ "$(sha256sum /etc/systemd/system/bhttp-server.service)" == "$S1" ]]; r2=$?; rm -f /etc/systemd/system/bhttp-server.service; systemctl daemon-reload; vpsarg-bhttp instalar --desde '"$BINDIR"' >/dev/null 2>&1; ((r == 0 && r2 == 0))'
check "instalado otra vez al terminar" bash -c 'systemctl is-active --quiet bhttp-shim && [[ -n "$(ss -Hltn "sport = :8001")" ]]'

echo "### Lo que no debe cambiar"
check "UDPGW no se reinició en toda la prueba (PID $UG_PID0)" test "$(pid_of udpgw-7300)" = "$UG_PID0"
check "sshd_config, unidades, binarios y confs de PDirect-C, UDPGW y HCR iguales" test "$(sums)" = "$SUMS0"
check "el registro no tiene contraseñas" bash -c '! journalctl -o cat | grep -q "'"$PW"'"'

pkill -f "bhttp-cliente.py" 2>/dev/null
kill "$(cat /run/sshd-2222.pid)" 2>/dev/null
for u in bhuno bhdos; do vpsarg-usuarios eliminar "$u" >/dev/null 2>&1; done
userdel -r bhshell 2>/dev/null
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
