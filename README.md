# VPS ARG QuickStart

Instalador para Ubuntu que compila e instala dos servicios ligeros, cada uno con su propia unidad systemd y arranque automático:

| Servicio | Unidad systemd | Escucha | Destino |
|---|---|---|---|
| PDirect-C | `pdirect-80.service` | `0.0.0.0:80/TCP` | SSH local `127.0.0.1:PUERTO_SSH` (22 por defecto) |
| BadVPN UDPGW | `udpgw-7300.service` | `0.0.0.0:7300/TCP` | — |

Incluye el controlador `vpsarg-puertos` para consultar estado, iniciar, detener, reiniciar, habilitar, deshabilitar y cambiar el puerto SSH de destino.

No instala panel web ni base de datos. **No modifica `sshd_config`, no reinicia SSH y no toca el firewall.**

## Requisitos

- Ubuntu 20.04, 22.04 o 24.04 con systemd (en otra versión el instalador avisa y pide confirmación).
- Acceso root (`sudo`) y conexión a Internet.
- Puertos TCP 80 y 7300 libres. Si otro programa los usa (por ejemplo nginx o apache en el 80), el instalador se detiene sin hacer cambios.
- Un servidor SSH escuchando en `127.0.0.1` en el puerto que vayas a indicar.

## Instalación

Comando único:

```bash
curl -fsSL https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main/install.sh -o /tmp/vpsarg-install.sh && sudo bash /tmp/vpsarg-install.sh
```

Para revisar el script antes de ejecutarlo:

```bash
curl -fsSL https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main/install.sh -o /tmp/vpsarg-install.sh
less /tmp/vpsarg-install.sh
sudo bash /tmp/vpsarg-install.sh
```

El instalador:

1. Comprueba root, Ubuntu, systemd y que TCP 80 y 7300 estén libres.
2. Si detecta una instalación previa, la lista y solo continúa si escribís `SI`.
3. Pregunta el puerto SSH local (Enter = 22, o el valor de una instalación previa) y comprueba que haya algo escuchando en `127.0.0.1:PUERTO`. Si no lo hay, avisa y pide confirmación.
4. Instala dependencias: `ca-certificates curl git cmake make gcc libc6-dev libevent-dev`.
5. Descarga `pdirect.c` y `vpsarg-puertos.sh` de la rama `main` y compila PDirect-C:
   `gcc -O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong -o pdirect-c pdirect.c -levent_core`
6. Clona BadVPN (`github.com/ambrop72/badvpn`) y compila solo UDPGW con CMake.
7. Instala los archivos, crea las unidades systemd, las habilita y comprueba que ambos servicios estén activos y escuchando.

Si cualquier paso crítico falla, se detiene con un mensaje de error. Hasta el paso 7 no se instala ni se reemplaza ningún archivo del sistema (salvo los paquetes de apt).

### Archivos instalados

| Ruta | Contenido |
|---|---|
| `/usr/local/bin/pdirect-c` | PDirect-C compilado |
| `/opt/badvpn/badvpn-udpgw` | BadVPN UDPGW compilado |
| `/usr/local/sbin/vpsarg-puertos` | Controlador |
| `/etc/vpsarg-pdirect.conf` | `SSH_PORT=22` — única fuente del puerto SSH de destino |
| `/etc/vpsarg-servicios.conf` | Servicios que maneja el controlador |
| `/etc/systemd/system/pdirect-80.service` | Unidad de PDirect-C |
| `/etc/systemd/system/udpgw-7300.service` | Unidad de UDPGW |

Ambos servicios corren con un usuario temporal sin privilegios (`DynamicUser=yes`). PDirect-C solo recibe la capacidad `CAP_NET_BIND_SERVICE` para abrir el puerto 80.

## Administración

```bash
sudo vpsarg-puertos estado                 # estado de ambos servicios, destino SSH y puertos en escucha
sudo vpsarg-puertos iniciar
sudo vpsarg-puertos detener
sudo vpsarg-puertos reiniciar
sudo vpsarg-puertos habilitar              # arranque automático + iniciar ahora
sudo vpsarg-puertos deshabilitar           # detener + quitar arranque automático
sudo vpsarg-puertos reiniciar pdirect-80   # cualquier acción sobre un solo servicio
sudo vpsarg-puertos detener udpgw-7300
```

## Puerto SSH de destino

PDirect-C siempre escucha en TCP 80 y reenvía a `127.0.0.1:PUERTO_SSH`. Para ver o cambiar ese puerto:

```bash
sudo vpsarg-puertos puerto-ssh          # muestra el puerto actual
sudo vpsarg-puertos puerto-ssh 2222     # cambia el destino a 127.0.0.1:2222
```

El cambio:

- Valida el número (1-65535) y comprueba que haya algo escuchando en `127.0.0.1:PUERTO`; si no, avisa y pide confirmación.
- Escribe `SSH_PORT=PUERTO` en `/etc/vpsarg-pdirect.conf` y reinicia solo `pdirect-80`.
- Si `pdirect-80` no arranca con el nuevo valor, restaura el anterior.
- No modifica sshd, el puerto 80, UDPGW ni el firewall.

**Importante:** este comando no cambia el puerto en el que escucha SSH. Si cambiás el puerto de sshd por tu cuenta, después ejecutá `puerto-ssh` con el puerto nuevo.

PDirect-C acepta la cabecera `X-Real-Host` solo si vale `127.0.0.1:PUERTO_SSH` o `localhost:PUERTO_SSH` (con el puerto configurado); si la cabecera no está, permite la conexión. Si tu payload incluye `X-Real-Host`, tiene que usar el mismo puerto.

## Diagnóstico

```bash
sudo vpsarg-puertos estado
systemctl status pdirect-80 udpgw-7300 --no-pager
journalctl -u pdirect-80 -n 50 --no-pager
journalctl -u udpgw-7300 -n 50 --no-pager
sudo ss -ltnp '( sport = :80 or sport = :7300 )'
sudo ss -ltnp | grep -E 'sshd|systemd'      # puerto real de SSH
cat /etc/vpsarg-pdirect.conf
```

Prueba local de PDirect-C (debe responder `HTTP/1.1 101` seguido del banner `SSH-2.0-...`):

```bash
printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' | timeout 3 nc 127.0.0.1 80
```

## Solución de problemas

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| El instalador dice que TCP 80 está en uso | nginx, apache u otro programa | Liberá el puerto o desinstalá ese programa; el instalador no lo toca. |
| `NO responde` en el destino SSH | SSH escucha en otro puerto | `sudo ss -ltnp \| grep -E 'sshd\|systemd'` y luego `sudo vpsarg-puertos puerto-ssh PUERTO`. |
| El cliente recibe `403 Forbidden` | `X-Real-Host` con otro puerto | Ajustá el payload al puerto configurado. |
| El cliente recibe `431` | Cabeceras de 16 KB o más | Acortá el payload. |
| El servicio está activo pero no hay acceso desde Internet | Firewall del sistema o del proveedor | Abrí TCP 80 y 7300 en el panel del proveedor y, si usás ufw, `sudo ufw allow 80/tcp` y `sudo ufw allow 7300/tcp`. |
| Un servicio aparece `failed` | Ver el log | `journalctl -u pdirect-80 -n 50` o `journalctl -u udpgw-7300 -n 50`. |

## Desinstalación

No toca SSH ni el firewall:

```bash
sudo systemctl disable --now pdirect-80 udpgw-7300
sudo rm -f /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw /usr/local/sbin/vpsarg-puertos \
           /etc/vpsarg-pdirect.conf /etc/vpsarg-servicios.conf
sudo rmdir /opt/badvpn
```

Los paquetes de compilación quedan instalados. Si los quitás, no elimines las bibliotecas `libevent` mientras uses PDirect-C.

## Seguridad y limitaciones

- No ejecutes scripts remotos como root sin revisarlos.
- El instalador no guarda ni muestra contraseñas ni credenciales.
- BadVPN upstream está archivado y sin mantenimiento activo; evaluá ese riesgo.
- UDPGW se configura con `--max-clients 3 --max-connections-for-client 256`. Si necesitás más clientes, editá `ExecStart` en `/etc/systemd/system/udpgw-7300.service` y ejecutá `sudo systemctl daemon-reload && sudo vpsarg-puertos reiniciar udpgw-7300`.
- PDirect-C cierra la conexión si el cliente o el servidor SSH pasan 60 segundos sin enviar datos (comportamiento del código original). Activá el keepalive en el cliente para sesiones inactivas.
