#!/usr/bin/env bash
# Consumo de cada servicio de VPS ARG QuickStart (solo lectura).
set -uo pipefail
printf '%-12s %-8s %-9s %-9s %-7s %-6s %-8s %s\n' SERVICIO PID RSS_kB CPU_ms HILOS FDS SOCKETS PROCESOS
for unit in pdirect-80 udpgw-7300 hcr-8880; do
  systemctl cat "$unit" >/dev/null 2>&1 || continue
  pid="$(systemctl show -p MainPID --value "$unit")"
  [[ "$pid" == 0 ]] && { printf '%-12s detenido\n' "$unit"; continue; }
  rss="$(awk '/VmRSS/{print $2}' "/proc/$pid/status")"
  thr="$(awk '/Threads/{print $2}' "/proc/$pid/status")"
  # utime+stime del proceso principal, en milisegundos
  cpu="$(awk -v hz="$(getconf CLK_TCK)" '{print int(($14+$15)*1000/hz)}' "/proc/$pid/stat")"
  fds="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 | wc -l)"
  socks="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 -lname 'socket:*' | wc -l)"
  procs="$(grep -l "/$unit.service" /proc/[0-9]*/cgroup 2>/dev/null | wc -l)"
  printf '%-12s %-8s %-9s %-9s %-7s %-6s %-8s %s\n' "$unit" "$pid" "$rss" "$cpu" "$thr" "$fds" "$socks" "$procs"
done
free -m | awk 'NR==2{print "RAM total/usada/disponible (MB): "$2"/"$3"/"$7}'
