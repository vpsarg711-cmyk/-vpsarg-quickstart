# VPS ARG QuickStart

Herramienta mínima para administrar los servicios systemd `pdirect-c` y
`udpgw-7300` en una VPS Ubuntu.

## Estado de esta versión

**Versión inicial: control de servicios existentes.** Instala el comando
`vpsarg-puertos`, pero **no instala PDirect-C ni UDPGW**, ni crea sus unidades
systemd o configuraciones. En una VPS nueva, primero deben instalarse y
configurarse esos servicios. No ejecutes comandos de inicio hasta verificar
que las unidades correspondan a los programas y puertos esperados.

## Publicar en GitHub

1. En GitHub, creá un repositorio nuevo llamado `vpsarg-quickstart`.
2. Elegí **Public**. No agregues contraseñas, tokens, claves privadas ni archivos
   de configuración de tus servidores.
3. En tu computadora, descomprimí esta carpeta o subí estos archivos:
   - `install.sh`
   - `vpsarg-puertos.sh`
   - `README.md`
4. Hacé el primer commit en la rama `main`.

## Instalar desde una VPS

Reemplazá `TU_USUARIO` por tu nombre de usuario real de GitHub. El repositorio
debe estar publicado y contener `install.sh` en la rama `main`.

```bash
curl -fsSL https://raw.githubusercontent.com/TU_USUARIO/vpsarg-quickstart/main/install.sh -o /tmp/vpsarg-install.sh
sudo bash /tmp/vpsarg-install.sh instalar
```

Este comando instala el comando de administración en `/usr/local/sbin`.
No instala los binarios de PDirect-C ni UDPGW.

## Comandos

```bash
sudo vpsarg-puertos iniciar
sudo vpsarg-puertos detener
sudo vpsarg-puertos reiniciar
sudo vpsarg-puertos estado
sudo vpsarg-puertos habilitar
sudo vpsarg-puertos deshabilitar
```

- `iniciar`: inicia ambos servicios.
- `detener`: detiene ambos servicios.
- `reiniciar`: reinicia ambos servicios.
- `estado`: muestra el estado y los puertos en escucha.
- `habilitar`: habilita el inicio automático y los inicia ahora.
- `deshabilitar`: los detiene y desactiva el inicio automático.

## Seguridad y limitaciones

- Revisá el contenido del script antes de ejecutarlo como root.
- Si el puerto 80 o 7300 está ocupado, no detengas procesos desconocidos
  automáticamente. Identificá primero qué programa lo utiliza.
- Un servicio `active` no garantiza accesibilidad desde Internet: verificá
  escucha, firewall y reglas del proveedor.
- El script presupone las unidades systemd `pdirect-c` y `udpgw-7300`.
- Esta versión no modifica SSH, firewall, usuarios de Servex ni reglas de red.
