#!/usr/bin/env bash
# Pruebas de laboratorio del límite de conexiones por usuario (etapa 3C, PAM).
# SOLO para una máquina o contenedor de laboratorio con QuickStart instalado:
# instala sshpass, crea y borra cuentas de prueba, activa y desactiva el control
# (/etc/pam.d/sshd) y entra por SSH de verdad, directo y a través de PDirect-C (TCP 80).
# No reinicia SSH, PDirect-C ni UDPGW ni toca sshd_config: se verifica al final.
# Uso: sudo bash tests/prueba-limite.sh
# shellcheck disable=SC2016
set -uo pipefail

PASS=0
FAILS=0
PW='Prueba-3c.Clave'      # contraseña de laboratorio
OUT=/tmp/limite.out
VERSION="$(. /etc/os-release; echo "$VERSION_ID")"
CLIENTS=()

ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
pid_of() { systemctl show -p MainPID --value "$1"; }
u() { vpsarg-usuarios "$@" > "$OUT" 2>&1; }
has() { grep -q -- "$1" "$OUT"; }
sessions_of() { vpsarg-usuarios listar | awk -v u="$1" '$1==u{print $(NF-1)}'; }
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
         -o ConnectTimeout=10 -o ServerAliveInterval=5)
proxy_for() { [[ "$1" == pdirect ]] && echo "ProxyCommand=python3 /tmp/pd-proxy.py" || echo "ProxyCommand=none"; }

# conn USUARIO [directo|pdirect]: abre una conexión ssh -N en segundo plano (PID en C).
conn() {
  SSHPASS="$PW" sshpass -e ssh "${SSHOPTS[@]}" -o "$(proxy_for "${2:-directo}")" -N "$1@127.0.0.1" </dev/null >/dev/null 2>&1 &
  C=$!
  CLIENTS+=("$C")
}
alive() { kill -0 "$1" 2>/dev/null; }
# wait_sessions USUARIO N: espera (hasta 15 s) a que el listado cuente N sesiones.
wait_sessions() {
  local _
  for _ in $(seq 30); do
    [[ "$(sessions_of "$1")" == "$2" ]] && return 0
    sleep 0.5
  done
  return 1
}
# accepted USUARIO [vía]: la conexión nueva entra y sigue abierta a los 6 s.
accepted() { conn "$@"; sleep 6; alive "$C"; }
# rejected USUARIO [vía]: la conexión nueva termina sola con error antes de 20 s.
rejected() {
  local rc=0
  SSHPASS="$PW" timeout 20 sshpass -e ssh "${SSHOPTS[@]}" -o "$(proxy_for "${2:-directo}")" -N "$1@127.0.0.1" </dev/null >"$OUT" 2>&1 || rc=$?
  ((rc != 0 && rc != 124))
}
close_all() {
  local p
  for p in "${CLIENTS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  CLIENTS=()
}
limit_log() { journalctl -t vpsarg-limite -o cat 2>/dev/null; }
create() { echo "$PW" | vpsarg-usuarios crear "$@" >/dev/null 2>&1; }
sums() {
  sha256sum /etc/ssh/sshd_config /etc/shells /etc/vpsarg-pdirect.conf /etc/pam.d/common-account \
    /etc/pam.d/common-auth /etc/pam.d/common-session /etc/pam.d/common-password \
    /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
    /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw
  find /etc/ssh/sshd_config.d /etc/profile.d -type f -exec sha256sum {} + 2>/dev/null
  ls -l /etc/vpsarg-auto.conf 2>/dev/null
}

echo "### Preparación (Ubuntu $VERSION)"
if ! command -v sshpass >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass openssh-client >/dev/null
fi
check "sshpass disponible (solo para la prueba)" command -v sshpass
# Cliente para entrar por PDirect-C (igual que en prueba-usuarios.sh).
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
cp -p /etc/pam.d/sshd /tmp/pam-sshd.original
SUMS0="$(sums)"
SSH_PID0="$(pid_of ssh)"
UG_PID0="$(pid_of udpgw-7300)"
PD_PID0="$(pid_of pdirect-80)"
check "sshd usa PAM (UsePAM yes)" bash -c '[[ "$(sshd -T | awk '"'"'$1=="usepam"{print $2}'"'"')" == yes ]]'
check "control inactivo al empezar" bash -c 'vpsarg-usuarios control | grep -q INACTIVO'
check "crear juan (límite por defecto 1)" create juan
check "crear ana con límite 1" create ana 30 1
check "listar avisa que el límite no se aplica" bash -c 'vpsarg-usuarios listar | grep -q "no se aplica: control de límites desactivado"'

echo "### Sin el control: el límite no se aplica"
conn juan; conn juan
check "juan abre 2 conexiones con límite 1" wait_sessions juan 2

echo "### Activar"
check "control on" u control on
check "informa la verificación correcta" has "Verificación correcta"
check "control ACTIVO" bash -c 'vpsarg-usuarios control | grep -q "ACTIVO (las"'
check "/etc/pam.d/sshd: solo 3 líneas nuevas después de @include common-account" bash -c '
  [[ "$(diff /tmp/pam-sshd.original /etc/pam.d/sshd | grep -c "^>")" == 3 && "$(diff /tmp/pam-sshd.original /etc/pam.d/sshd | grep -c "^<")" == 0 ]] \
  && grep -A3 -x "@include common-account" /etc/pam.d/sshd | sed -n 3p | grep -qx "account \[success=1 default=ignore\] pam_succeed_if.so quiet user notingroup vpsarg-usuarios" \
  && grep -A3 -x "@include common-account" /etc/pam.d/sshd | sed -n 4p | grep -qx "account required pam_exec.so stdout quiet /usr/local/sbin/vpsarg-limite"'
check "/etc/pam.d/sshd sigue 0644 root" test "$(stat -c '%a %U' /etc/pam.d/sshd)" = "644 root"
check "copia previa guardada (0600) e igual al original" bash -c 'cmp -s /tmp/pam-sshd.original /etc/vpsarg/pam-sshd.antes-del-limite && [[ "$(stat -c %a /etc/vpsarg/pam-sshd.antes-del-limite)" == 600 ]]'
check "vpsarg-limite instalado 0755 root" test "$(stat -c '%a %U' /usr/local/sbin/vpsarg-limite)" = "755 root"
check "la cuenta temporal de verificación no quedó" bash -c '! getent passwd vpsarg-verif >/dev/null && ! grep -q "^vpsarg-verif:" /etc/vpsarg/limites && ! ls -d /run/vpsarg-verif.* 2>/dev/null'
check "SSH no se reinició" test "$(pid_of ssh)" = "$SSH_PID0"
check "registro: control on ok" bash -c 'journalctl -t vpsarg-panel -o cat | grep -q "accion=control valor=on resultado=ok"'
check "activar otra vez no duplica las líneas" bash -c 'vpsarg-usuarios control on >/dev/null && [[ $(grep -c vpsarg-limite /etc/pam.d/sshd) == 1 ]]'
check "las 2 conexiones abiertas antes de activar siguen" bash -c 'sleep 1; for p in "$@"; do kill -0 "$p" || exit 1; done' _ "${CLIENTS[@]}"
check "esas 2 conexiones cuentan: la 3.ª se rechaza" rejected juan
check "las 2 conexiones siguen después del rechazo" bash -c 'sleep 1; for p in "$@"; do kill -0 "$p" || exit 1; done' _ "${CLIENTS[@]}"
check "listar dice que el límite se aplica" bash -c 'vpsarg-usuarios listar | grep -q "(- = sin límite); se aplica"'
close_all
check "juan sin sesiones" wait_sessions juan 0

echo "### Límite 1"
check "1.ª conexión aceptada" accepted juan
C1="$C"
check "2.ª conexión rechazada" rejected juan
check "el cliente OpenSSH muestra el motivo" bash -c 'SSHPASS="$1" timeout 20 sshpass -e ssh -o LogLevel=INFO "${@:2}" -N juan@127.0.0.1 2>&1 | grep -q "CONEXION RECHAZADA: limite de conexiones alcanzado (1/1)"' _ "$PW" "${SSHOPTS[@]}"
check "registro: rechazada usuario=juan actuales=1 limite=1" bash -c 'journalctl -t vpsarg-limite -o cat | grep -q "rechazada usuario=juan actuales=1 limite=1"'
check "la 1.ª sigue abierta después del rechazo" bash -c "sleep 1; kill -0 $C1"
check "sigue 1 sesión" wait_sessions juan 1
check "otra cuenta (ana, límite 1) entra igual" accepted ana
kill "$C1"; wait "$C1" 2>/dev/null
check "al cerrar la 1.ª (directo), una nueva entra enseguida" accepted juan
close_all; wait_sessions juan 0; wait_sessions ana 0

echo "### Límite 2: la 3.ª no expulsa a las 2 existentes"
check "limite juan 2" u limite juan 2
check "1.ª aceptada" accepted juan; C1="$C"
check "2.ª aceptada" accepted juan; C2="$C"
for i in 1 2 3; do
  check "intento $i de 3.ª conexión rechazado" rejected juan
done
check "la 1.ª y la 2.ª siguen abiertas" bash -c "sleep 2; kill -0 $C1 && kill -0 $C2"
check "siguen exactamente 2 sesiones" wait_sessions juan 2
check "registro: rechazada actuales=2 limite=2" bash -c 'journalctl -t vpsarg-limite -o cat | grep -q "rechazada usuario=juan actuales=2 limite=2"'

echo "### Cambiar el límite con conexiones abiertas"
check "bajar a 1 no cierra ninguna" bash -c "vpsarg-usuarios limite juan 1 >/dev/null; sleep 2; kill -0 $C1 && kill -0 $C2"
check "Estado marca juan 2/1 EXCEDE" bash -c 'vpsarg sistema | grep -qE "^  juan +2/1  EXCEDE$"'
check "con 2/1 una nueva se rechaza" rejected juan
check "subir a 3" u limite juan 3
check "3.ª aceptada con límite 3" accepted juan
check "4.ª rechazada con límite 3" rejected juan
check "las 3 siguen abiertas" bash -c 'for p in "$@"; do kill -0 "$p" || exit 1; done' _ "${CLIENTS[@]}"
close_all; wait_sessions juan 0
check "límite 0 = sin límite" u limite juan 0
for i in 1 2 3 4; do check "conexión $i aceptada sin límite" accepted juan; done
close_all; wait_sessions juan 0
check "límite 5" u limite juan 5
for i in 1 2 3 4 5; do conn juan; done
check "5 conexiones con límite 5" wait_sessions juan 5
check "6.ª rechazada con límite 5" rejected juan
close_all; wait_sessions juan 0

echo "### Conexiones simultáneas (10 a la vez, límite 2, 3 rondas)"
vpsarg-usuarios limite juan 2 >/dev/null
for r in 1 2 3; do
  for i in $(seq 10); do conn juan; done
  sleep 12
  n=0; for p in "${CLIENTS[@]}"; do alive "$p" && n=$((n + 1)); done
  check "ronda $r: quedan exactamente 2 conexiones ($n clientes vivos, $(sessions_of juan) sesiones)" bash -c "[[ $n == 2 && \$(vpsarg-usuarios listar | awk '\$1==\"juan\"{print \$(NF-1)}') == 2 ]]"
  close_all; wait_sessions juan 0
done

echo "### PDirect-C (TCP 80), límite 1"
vpsarg-usuarios limite juan 1 >/dev/null
check "1.ª conexión por PDirect-C aceptada" accepted juan pdirect
C1="$C"
check "2.ª por PDirect-C rechazada" rejected juan pdirect
check "2.ª directa rechazada" rejected juan
check "la 1.ª por PDirect-C sigue abierta" bash -c "sleep 1; kill -0 $C1"
kill "$C1"; wait "$C1" 2>/dev/null
close_all; wait_sessions juan 0 || sleep 70
# PDirect-C (pdirect.c, sin cambios) no atiende el cierre del lado del cliente: si el
# cliente desaparece sin cerrar la sesión SSH, la conexión hacia SSH sigue hasta la espera
# de 60 s sin datos de PDirect-C y cuenta para el límite.
# reconnect MODO: abre por PDirect-C, cierra (ordenado = ssh -O exit; abrupto = kill -9 del
# cliente) y reintenta cada 2 s hasta que una nueva entra (máx. 90 s). Deja FIRST y RECONNECT.
reconnect() {
  local t0 p
  rm -f /tmp/cm
  SSHPASS="$PW" sshpass -e ssh "${SSHOPTS[@]}" -o "$(proxy_for pdirect)" -M -S /tmp/cm -N juan@127.0.0.1 </dev/null >/dev/null 2>&1 &
  p=$!
  sleep 5
  if [[ "$1" == ordenado ]]; then
    ssh -S /tmp/cm -O exit juan@127.0.0.1 >/dev/null 2>&1
  else
    pkill -9 -f "pd-proxy.py"; pkill -9 -f "^ssh .*-S /tmp/cm"
  fi
  wait "$p" 2>/dev/null
  t0=$SECONDS; FIRST=""; RECONNECT=""
  while ((SECONDS - t0 < 90)); do
    if accepted juan pdirect; then RECONNECT=$((SECONDS - t0 - 6)); FIRST="${FIRST:-aceptada}"; break; fi
    FIRST="${FIRST:-rechazada}"
    sleep 2
  done
  echo "      Ubuntu $VERSION, cierre $1: reconexión inmediata ${FIRST:-sin dato}; nueva conexión aceptada a los ${RECONNECT:-más de 90} s"
  close_all; wait_sessions juan 0 || sleep 70
}
reconnect abrupto
check "cierre abrupto: la reconexión inmediata se rechaza (la conexión vieja cuenta ~60 s)" test "$FIRST" = rechazada
check "cierre abrupto: una nueva entra dentro de 75 s" test "${RECONNECT:-999}" -le 75
check "el rechazo en esa ventana es por el límite (registro)" bash -c 'journalctl -t vpsarg-limite -o cat | grep -q "rechazada usuario=juan actuales=1 limite=1"'
reconnect ordenado
check "cierre ordenado: una nueva entra dentro de 75 s" test "${RECONNECT:-999}" -le 75

echo "### Cuentas que no son del grupo"
useradd -m -s /bin/bash admin3
echo "admin3:$PW" | chpasswd
echo "admin3:1" >> /etc/vpsarg/limites   # aunque tuviera una línea, no se le aplica
for i in 1 2 3; do check "administrador (fuera del grupo) conexión $i aceptada" accepted admin3; done
check "vpsarg-limite no se ejecutó para admin3" bash -c '! journalctl -t vpsarg-limite -o cat | grep -q "usuario=admin3"'
close_all
sed -i '/^admin3:/d' /etc/vpsarg/limites
sleep 1; pkill -u admin3 2>/dev/null; sleep 2; userdel -r admin3 >/dev/null 2>&1 || { sleep 5; userdel -r admin3 >/dev/null 2>&1; }

echo "### Vencimiento, suspensión y eliminación con el control activo"
TODAY=$(( $(date +%s) / 86400 ))
N0="$(limit_log | grep -c "usuario=ana" || true)"
chage -E "$TODAY" ana
check "vencida: no entra" rejected ana
check "vencida: la rechaza el vencimiento (pam_unix), no el límite" test "$(limit_log | grep -c "usuario=ana" || true)" = "$N0"
chage -E -1 ana
check "ana entra (límite 1)" accepted ana; C1="$C"
chage -E "$TODAY" ana
check "vencida con la sesión abierta: la sesión sigue" bash -c "sleep 2; kill -0 $C1"
chage -E -1 ana
check "suspender ana cierra su sesión" bash -c 'vpsarg-usuarios suspender ana | grep -q "Sesiones SSH cerradas: 1"'
check "reactivar ana" u reactivar ana
check "reactivada: entra (el registro de la sesión cerrada no cuenta)" accepted ana
close_all; wait_sessions ana 0
check "eliminar ana" u eliminar ana
check "crear ana otra vez con límite 1" create ana 30 1
check "la nueva ana entra" accepted ana
close_all; wait_sessions ana 0

echo "### Desactivar con conexiones abiertas"
vpsarg-usuarios limite juan 1 >/dev/null
check "juan entra (límite 1)" accepted juan; C1="$C"
check "control off" u control off
check "informa que quedó como antes" has "quedó igual que antes de activar el control"
check "/etc/pam.d/sshd igual al original" cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd
check "vpsarg-limite borrado" test ! -e /usr/local/sbin/vpsarg-limite
check "registro de sesiones borrado" test ! -e /run/vpsarg/sesiones
check "la conexión abierta siguió" bash -c "sleep 1; kill -0 $C1"
check "sin control, juan abre una 2.ª conexión" accepted juan
check "SSH no se reinició" test "$(pid_of ssh)" = "$SSH_PID0"
check "control off otra vez: sin cambios" bash -c 'vpsarg-usuarios control off | grep -q INACTIVO && cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd'
close_all; wait_sessions juan 0

echo "### Activación que falla: se revierte"
mkdir -p /tmp/falso
printf '#!/bin/sh\nexit 255\n' > /tmp/falso/ssh
chmod 0755 /tmp/falso/ssh
check "verificación fallida: control on termina con error" bash -c '! PATH=/tmp/falso:$PATH vpsarg-usuarios control on > /tmp/limite.out 2>&1'
check "informa la reversión" has "Se revirtió"
check "/etc/pam.d/sshd quedó igual al original" cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd
check "sin vpsarg-limite ni cuenta temporal" bash -c '[[ ! -e /usr/local/sbin/vpsarg-limite ]] && ! getent passwd vpsarg-verif >/dev/null'
rm -rf /tmp/falso
mkdir -p /tmp/falso
printf '#!/bin/bash\n/usr/sbin/sshd "$@" | sed "s/^usepam .*/usepam no/"\n' > /tmp/falso/sshd
chmod 0755 /tmp/falso/sshd
check "con UsePAM no se niega" bash -c 'PATH=/tmp/falso:$PATH vpsarg-usuarios control on 2>&1 | grep -q "no usa PAM" && cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd'
rm -rf /tmp/falso
useradd -M vpsarg-verif
check "con una cuenta vpsarg-verif existente se niega" bash -c 'vpsarg-usuarios control on 2>&1 | grep -q "ya existe la cuenta vpsarg-verif" && cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd'
userdel vpsarg-verif
check "sin root se niega" bash -c '! setpriv --reuid=65534 --regid=65534 --clear-groups /usr/local/sbin/vpsarg-usuarios control on >/dev/null 2>&1 && cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd'

echo "### Desde el panel (Configuración › Límite de conexiones)"
printf '4\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "Configuración muestra la opción 8 INACTIVO" has "8) Límite de conexiones por usuario (INACTIVO)"
printf '4\n8\nn\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: responder n no activa" cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd
check "panel: avisa de los ~60 s de PDirect-C" has "PDirect-C sigue contando hasta ~60 s"
printf '4\n8\ns\n\n0\n0\n' | timeout 120 vpsarg > "$OUT" 2>&1
check "panel: activar" bash -c 'vpsarg-usuarios control | grep -q "ACTIVO (las"'
printf '4\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "Configuración muestra ACTIVO" has "8) Límite de conexiones por usuario (ACTIVO)"
check "panel activo: juan 1.ª aceptada" accepted juan
check "panel activo: juan 2.ª rechazada" rejected juan
close_all; wait_sessions juan 0
printf '4\n8\ns\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "panel: desactivar deja /etc/pam.d/sshd como el original" cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd

echo "### Lo que no debe cambiar"
vpsarg-usuarios eliminar juan >/dev/null 2>&1
vpsarg-usuarios eliminar ana >/dev/null 2>&1
check "no quedan cuentas de prueba" bash -c '! getent passwd juan ana admin3 vpsarg-verif >/dev/null'
check "contraseña fuera del registro" bash -c '! journalctl -o cat | grep -qF "$1"' _ "$PW"
check "SSH no se reinició (PID $SSH_PID0)" test "$(pid_of ssh)" = "$SSH_PID0"
check "UDPGW no se reinició (PID $UG_PID0)" test "$(pid_of udpgw-7300)" = "$UG_PID0"
check "PDirect-C no se reinició (PID $PD_PID0)" test "$(pid_of pdirect-80)" = "$PD_PID0"
check "sshd_config, PAM común, shells, profile.d, AUTO, unidades y binarios iguales" test "$(sums)" = "$SUMS0"
check "/etc/pam.d/sshd igual al original" cmp -s /tmp/pam-sshd.original /etc/pam.d/sshd

echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
