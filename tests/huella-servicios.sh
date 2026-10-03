#!/usr/bin/env bash
# Huella de PDirect-C y UDPGW para comparar antes/después (solo lectura).
# Uso: sudo bash tests/huella-servicios.sh > antes.txt   ...   diff antes.txt despues.txt
# La sección "Procesos" (PID, memoria) cambia con los reinicios y se compara aparte.
set -uo pipefail

for unit in pdirect-80 udpgw-7300; do
  echo "== $unit"
  echo "unidad_sha256=$(sha256sum "/etc/systemd/system/$unit.service" | cut -d' ' -f1)"
  echo "ExecStart=$(systemctl show -p ExecStart --value "$unit" | sed 's/ ; pid=.*//; s/start_time=.*//')"
  echo "enabled=$(systemctl is-enabled "$unit")"
  echo "active=$(systemctl is-active "$unit")"
  pid="$(systemctl show -p MainPID --value "$unit")"
  if [[ "$pid" != 0 ]]; then
    echo "cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    echo "binario_sha256=$(sha256sum "$(readlink "/proc/$pid/exe")" | cut -d' ' -f1)"
    echo "escucha=$(ss -Hltnp | grep "pid=$pid," | awk '{print $4}' | sort | tr '\n' ' ')"
  fi
done
echo "== configuración"
echo "vpsarg-pdirect.conf=$(cat /etc/vpsarg-pdirect.conf)"
echo "pdirect-c_sha256=$(sha256sum /usr/local/bin/pdirect-c | cut -d' ' -f1)"
echo "badvpn-udpgw_sha256=$(sha256sum /opt/badvpn/badvpn-udpgw | cut -d' ' -f1)"
echo "== funcional"
# shellcheck disable=SC2016  # el script interno se expande en el bash hijo
r="$(timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
  printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3
  for _ in 1 2 3 4 5 6 7 8; do IFS= read -r -t 4 l <&3 || exit 1; [[ "$l" == SSH-* ]] && { echo "${l%%$'"'"'\r'"'"'}"; exit 0; }; done; exit 1' 2>/dev/null)"
echo "pdirect_80_a_ssh=${r:-FALLA}"
if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/7300' 2>/dev/null; then echo "udpgw_7300_tcp=acepta"; else echo "udpgw_7300_tcp=FALLA"; fi
