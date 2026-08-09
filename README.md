# adguard-toolkit

Instalador y "mejorador" independiente para **AdGuard Home + Unbound** en Debian/Ubuntu.

Un solo script, sin dependencias raras: detecta qué hay en la máquina y se adapta.

- Si **AdGuard Home no está instalado** → ofrece instalarlo.
- Si **AdGuard Home ya está instalado** → ofrece mejorarlo añadiendo **Unbound** como
  resolver recursivo local con DNSSEC, de modo que AdGuard deje de depender de un
  DNS público y resuelva por sí mismo desde los servidores raíz.

AdGuard Home sigue siendo el DNS que ven tus clientes en el puerto 53. Unbound queda
escuchando solo en `127.0.0.1:5335`, sin exponerse a la red.

```
clientes  →  AdGuard Home (:53, filtrado)  →  Unbound (127.0.0.1:5335, recursivo)  →  raíz DNS
```

## Uso

```bash
scp adguard-toolkit.sh root@TU_SERVIDOR:/root/
ssh root@TU_SERVIDOR
chmod +x /root/adguard-toolkit.sh
/root/adguard-toolkit.sh
```

Sin argumentos abre un menú que cambia según lo que encuentre en el sistema.

### Modo no interactivo

| Comando | Qué hace |
| --- | --- |
| `--status` | Diagnóstico. No modifica nada. |
| `--unbound` | Añade o reconfigura Unbound. Idempotente. |
| `--install-adguard` | Instala AdGuard Home con el instalador oficial. |
| `--all` | Instala AdGuard si falta y después añade Unbound. |
| `--revert-unbound` | Deshace la mejora y restaura la configuración anterior. |

Modificadores:

| Flag | Efecto |
| --- | --- |
| `-y`, `--yes` | No preguntar nada. Para automatización. |
| `--port N` | Puerto de Unbound. Por defecto `5335`. |
| `--keep-fallback` | Conserva el `fallback_dns` externo de AdGuard. |

Ejemplo desatendido:

```bash
./adguard-toolkit.sh --all --yes --keep-fallback
```

## Qué configura en Unbound

DNSSEC validando, `qname-minimisation`, `prefetch` y `prefetch-key`, `serve-expired`,
`aggressive-nsec`, endurecimiento (`harden-glue`, `harden-dnssec-stripped`,
`harden-below-nxdomain`), y tamaños de caché e hilos calculados automáticamente
según la CPU y la RAM de la máquina.

## Seguridad de la operación

- Antes de tocar nada guarda una copia del `AdGuardHome.yaml` en
  `/root/adguard-unbound-backups/<fecha>/`.
- Tras aplicar el cambio verifica que la cadena completa resuelve. **Si AdGuard no
  vuelve a responder, restaura sola la configuración anterior** y te deja el DNS
  funcionando.
- `--revert-unbound` recupera el último backup y, opcionalmente, desinstala Unbound.

## Detalles que este script resuelve por ti

Cuatro cosas que rompen la mayoría de guías y scripts que circulan por ahí:

1. **`auto-trust-anchor-file` duplicado.** Debian ya lo declara en
   `/etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf`. Si tu configuración
   lo repite, Unbound carga el mismo trust anchor dos veces y aborta al arrancar con
   `error: trust anchor presented twice`.
2. **Colisión en el puerto 53 al instalar.** El `postinst` del paquete de Debian
   arranca Unbound en `127.0.0.1:53`, que choca con AdGuard Home. Este script escribe
   la configuración con el puerto correcto *antes* de `apt-get install`.
3. **AdGuard Home no vive siempre en `/opt`.** El instalador oficial se ejecuta a
   menudo desde `/root`, así que el `AdGuardHome.yaml` acaba en `/root/AdGuardHome/`.
   Aquí se busca en ocho rutas, por el `cwd` del proceso y por búsqueda acotada.
4. **AdGuard tarda en responder tras reiniciarse.** Bastante más de 3 segundos, porque
   carga las listas de bloqueo. Comprobar una sola vez hace que una reversión
   automática se dispare sobre una configuración perfectamente válida; aquí se
   reintenta durante 40 segundos.

También enmascara `unbound-resolvconf.service`, que falla en bucle cuando
`/etc/resolv.conf` no es un enlace gestionado por `resolvconf`.

## Requisitos

- Debian o Ubuntu (usa `apt`).
- Ejecutar como `root`.
- Que AdGuard Home escuche en el puerto 53 (o que vayas a instalarlo con este script).

## Notas

- **No expongas el puerto de Unbound a Internet ni a tus clientes.** Solo AdGuard
  debe consultarlo.
- Por defecto se vacía `fallback_dns`, de forma que Unbound sea el único camino. Eso
  significa que **si Unbound cae, la red se queda sin DNS**. Usa `--keep-fallback` si
  prefieres tener red de seguridad a costa de que, cuando Unbound falle, algunas
  consultas salgan a un DNS externo.
- Pasar de un upstream cifrado (DoT/DoH) a resolución recursiva cambia el modelo de
  privacidad: dejas de confiar en un proveedor único, pero las consultas a los
  servidores autoritativos viajan en claro y tu ISP puede verlas.
- La rama de instalación de AdGuard Home usa el instalador oficial de AdGuardTeam.

## Licencia

MIT. Ver [LICENSE](LICENSE).
