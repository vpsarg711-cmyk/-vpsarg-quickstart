#!/usr/bin/env bash
# Pruebas de laboratorio del componente HCR (Fase 2A).
# SOLO para una máquina o contenedor de laboratorio con QuickStart instalado:
# inicia un sshd extra en 127.0.0.1:2222, un servidor web temporal en 8081
# y reemplaza por un momento el binario de HCR para provocar un fallo.
# Uso: sudo bash tests/prueba-hcr.sh /ruta/al/hcr-server
# Los scripts entre comillas simples se expanden en el bash hijo.
# shellcheck disable=SC2016
set -uo pipefail

SRC="${1:?Uso: sudo bash tests/prueba-hcr.sh /ruta/al/hcr-server}"
BIN=/usr/local/lib/vpsarg/hcr-server
PASS=0
FAILS=0

ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
listening() { [[ -n "$(ss -Hltn "sport = :$1")" ]]; }
hcr_pid() { systemctl show -p MainPID --value hcr-8880; }
hcr_arg() { tr '\0' '\n' < "/proc/$(hcr_pid)/cmdline" | grep -A1 -x -- "$1" | tail -n 1; }
pd_port() { tr '\0' '\n' < "/proc/$(systemctl show -p MainPID --value pdirect-80)/cmdline" | sed -n 2p; }
ssh_banner() {
  timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1; IFS= read -r -t 4 l <&3 && [[ "$l" == SSH-* ]]' _ "$1" 2>/dev/null
}
pdirect_ssh() {
  timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
    printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3
    for _ in 1 2 3 4 5 6 7 8; do IFS= read -r -t 4 l <&3 || exit 1; [[ "$l" == SSH-* ]] && exit 0; done; exit 1' 2>/dev/null
}
conf() { sed -n "s/^$1=//p" /etc/vpsarg-hcr.conf; }

echo "### Preparación"
install -d -m 0755 /opt/hcr
install -o root -g root -m 0755 "$SRC" /opt/hcr/hcr-server
mkdir -p /run/sshd
/usr/sbin/sshd -p 2222 -o PidFile=/run/sshd-2222.pid
sleep 1
check "sshd de prueba responde en 127.0.0.1:2222" ssh_banner 2222
PD_PID0="$(systemctl show -p MainPID --value pdirect-80)"
UG_PID0="$(systemctl show -p MainPID --value udpgw-7300)"

echo "### Instalación"
check "rechaza un binario con sha256 distinto" \
  bash -c 'cp /opt/hcr/hcr-server /tmp/hcr-mod && printf x >> /tmp/hcr-mod && ! vpsarg-hcr instalar --binario /tmp/hcr-mod >/dev/null 2>&1 && ! test -e /etc/systemd/system/hcr-8880.service'
check "instalar" vpsarg-hcr instalar
check "hcr-8880 activo" systemctl is-active --quiet hcr-8880
check "habilitado al arranque" systemctl is-enabled --quiet hcr-8880
check "escucha en TCP 8880" listening 8880
check "el proceso no es root (usuario $(ps -o user= -p "$(hcr_pid)"))" test "$(ps -o uid= -p "$(hcr_pid)" | tr -d ' ')" != 0
check "sin capacidades efectivas" test "$(awk '/CapEff/{print $2}' "/proc/$(hcr_pid)/status")" = 0000000000000000
check "destino 127.0.0.1:22 (puerto real de PDirect-C)" test "$(hcr_arg -target)" = 127.0.0.1:22
check "transporte plain" test "$(hcr_arg -transport)" = plain
check "-max-sessions 32" test "$(hcr_arg -max-sessions)" = 32
check "-max-sessions-per-ip 16" test "$(hcr_arg -max-sessions-per-ip)" = 16
check "el journal confirma 32/16" \
  bash -c 'journalctl -u hcr-8880 -o cat | grep runtime_configured | tail -n 1 | grep -q "\"max_sessions\":32,\"max_sessions_per_source\":16"'
check "segunda instalación (sin duplicar)" vpsarg-hcr instalar
check "una sola unidad hcr-8880" test "$(systemctl list-unit-files --no-legend 'hcr-8880*' | wc -l)" = 1
check "una sola línea en vpsarg-servicios.conf" test "$(grep -cx hcr-8880 /etc/vpsarg-servicios.conf)" = 1

echo "### Detener, iniciar, reiniciar"
check "detener" vpsarg-hcr detener
check "detenido y sin escuchar" bash -c '! systemctl is-active --quiet hcr-8880 && [[ -z "$(ss -Hltn "sport = :8880")" ]]'
check "iniciar" vpsarg-hcr iniciar
check "escucha tras iniciar" listening 8880
P1="$(hcr_pid)"
check "reiniciar" vpsarg-hcr reiniciar
check "PID nuevo tras reiniciar" test "$(hcr_pid)" != "$P1"
check "estado" bash -c 'vpsarg-hcr estado >/dev/null'
check "vpsarg-puertos estado muestra el puerto de HCR" bash -c 'vpsarg-puertos estado 2>/dev/null | grep -q ":8880"'

echo "### Puertos"
check "rechaza 80"   bash -c '! vpsarg-hcr puerto 80 >/dev/null 2>&1'
check "rechaza 7300" bash -c '! vpsarg-hcr puerto 7300 >/dev/null 2>&1'
check "rechaza 1000 (< 1024)" bash -c '! vpsarg-hcr puerto 1000 >/dev/null 2>&1'
python3 -m http.server 8081 --bind 127.0.0.1 >/dev/null 2>&1 &
WEB=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do listening 8081 && break; sleep 0.5; done
check "servidor web de prueba escucha en 8081" listening 8081
check "rechaza 8081 ocupado por otro programa" bash -c '! vpsarg-hcr puerto 8081 >/dev/null 2>&1'
check "no detuvo el programa del 8081" kill -0 "$WEB"
kill "$WEB"
check "sigue en 8880 tras el rechazo" test "$(conf HCR_PORT)" = 8880
check "cambiar 8880 -> 8080" vpsarg-hcr puerto 8080
check "escucha en 8080" listening 8080
check "ya no escucha en 8880" bash -c '[[ -z "$(ss -Hltn "sport = :8880")" ]]'
check "restaurar 8080 -> 8880" vpsarg-hcr puerto 8880
check "escucha otra vez en 8880" listening 8880

echo "### Destino SSH (vpsarg-puertos puerto-ssh)"
check "puerto-ssh 2222" vpsarg-puertos puerto-ssh 2222
check "PDirect-C apunta a 2222" test "$(pd_port)" = 2222
check "HCR apunta a 127.0.0.1:2222" test "$(hcr_arg -target)" = 127.0.0.1:2222
check "conexión por PDirect-C llega a SSH en 2222" pdirect_ssh
check "SSH sigue respondiendo en 2222" ssh_banner 2222
check "UDPGW no se reinició" test "$(systemctl show -p MainPID --value udpgw-7300)" = "$UG_PID0"
check "puerto-ssh 22 (volver)" vpsarg-puertos puerto-ssh 22
check "PDirect-C y HCR otra vez en 22" bash -c "[[ \"\$(tr '\\0' '\\n' < /proc/\$(systemctl show -p MainPID --value pdirect-80)/cmdline | sed -n 2p)\" == 22 ]] && grep -qx HCR_SSH_PORT=22 /etc/vpsarg-hcr.conf"

echo "### Reversión cuando HCR falla"
mv "$BIN" "$BIN.real"
cat > "$BIN" <<'EOF'
#!/bin/bash
# Binario de prueba: falla solo con destino 2222.
case "$*" in *127.0.0.1:2222*) exit 1 ;; esac
exec /usr/local/lib/vpsarg/hcr-server.real "$@"
EOF
chmod 0755 "$BIN"
systemctl restart hcr-8880
sleep 1
check "puerto-ssh 2222 falla porque HCR no arranca" bash -c '! vpsarg-puertos puerto-ssh 2222 >/tmp/rollback.log 2>&1'
check "la reversión informa que quedó verificada" grep -q "Reversión verificada: PDirect-C activo, escucha en TCP 80, apunta a 127.0.0.1:22 y llega a SSH" /tmp/rollback.log
# Sin espera: puerto-ssh ya no termina hasta verificar la reversión.
check "PDirect-C volvió a 22 (inmediatamente)" test "$(pd_port)" = 22
check "configuración de PDirect-C en 22" grep -qx SSH_PORT=22 /etc/vpsarg-pdirect.conf
check "HCR volvió a 22" test "$(conf HCR_SSH_PORT)" = 22
sleep 1
check "HCR activo tras la reversión" systemctl is-active --quiet hcr-8880
check "PDirect-C llega a SSH tras la reversión" pdirect_ssh
systemctl stop pdirect-80
check "con PDirect-C detenido: puerto-ssh 2222 falla y revierte" bash -c '! vpsarg-puertos puerto-ssh 2222 >/tmp/rollback2.log 2>&1'
check "informa la reversión con PDirect-C detenido" grep -q "Reversión verificada: /etc/vpsarg-pdirect.conf vuelve a 22 (PDirect-C estaba detenido)" /tmp/rollback2.log
check "PDirect-C sigue detenido y su configuración en 22" bash -c '! systemctl is-active --quiet pdirect-80 && grep -qx SSH_PORT=22 /etc/vpsarg-pdirect.conf'
systemctl start pdirect-80
sleep 1
mv -f "$BIN.real" "$BIN"
systemctl restart hcr-8880
sleep 1

echo "### Desinstalación"
PD_PID1="$(systemctl show -p MainPID --value pdirect-80)"
check "desinstalar" vpsarg-hcr desinstalar
check "sin unidad hcr-8880" bash -c '! test -e /etc/systemd/system/hcr-8880.service'
check "sin binario ni configuración" bash -c '! test -e /usr/local/lib/vpsarg/hcr-server && ! test -e /etc/vpsarg-hcr.conf'
check "sin línea en vpsarg-servicios.conf" bash -c '! grep -qx hcr-8880 /etc/vpsarg-servicios.conf'
check "no escucha en 8880" bash -c '[[ -z "$(ss -Hltn "sport = :8880")" ]]'
check "el original /opt/hcr/hcr-server sigue" test -f /opt/hcr/hcr-server
check "PDirect-C no se reinició al desinstalar HCR" test "$(systemctl show -p MainPID --value pdirect-80)" = "$PD_PID1"
check "UDPGW no se reinició en toda la prueba" test "$(systemctl show -p MainPID --value udpgw-7300)" = "$UG_PID0"
check "PDirect-C sigue llegando a SSH" pdirect_ssh
check "desinstalar otra vez no falla" vpsarg-hcr desinstalar
echo "(PDirect-C se reinició durante las pruebas de puerto-ssh: PID $PD_PID0 -> $PD_PID1, esperado)"

kill "$(cat /run/sshd-2222.pid)" 2>/dev/null
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
