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

## ⚡ Quick install (one-liner)

Como `root` en tu servidor Debian/Ubuntu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mtandazo35/adguard-toolkit/main/adguard-toolkit.sh)
```

Abre el menú interactivo, que cambia según lo que encuentre en la máquina.

**Desatendido**, sin preguntas (instala AdGuard si falta y luego añade Unbound):

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/adguard-toolkit/main/adguard-toolkit.sh | bash -s -- --all --yes
```

**Solo diagnóstico**, no toca nada:

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/adguard-toolkit/main/adguard-toolkit.sh | bash -s -- --status
```

> **Ojo con `curl … | bash` sin flags.** Al tuberizar, la entrada estándar deja de ser
> una terminal y el menú no puede leer tus respuestas. En ese caso el script no
> adivina nada: se comporta como `--status` y no modifica el sistema. Para el menú
> usa la forma `bash <(curl …)`, que conserva la terminal en stdin.

Si prefieres revisar el script antes de ejecutarlo — recomendable con cualquier
instalador que venga de Internet:

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/adguard-toolkit/main/adguard-toolkit.sh -o adguard-toolkit.sh
less adguard-toolkit.sh
chmod +x adguard-toolkit.sh
./adguard-toolkit.sh
```

## Uso

También puedes copiarlo a mano:

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
| `--no-fallback` | Vacía el `fallback_dns` de AdGuard: Unbound queda como único camino. |

Ejemplo desatendido:

```bash
./adguard-toolkit.sh --all --yes
```

## Qué configura en Unbound

DNSSEC validando, `qname-minimisation`, `prefetch` y `prefetch-key`, `serve-expired`,
`aggressive-nsec`, endurecimiento (`harden-glue`, `harden-dnssec-stripped`,
`harden-below-nxdomain`), y tamaños de caché e hilos calculados automáticamente
según la CPU y la RAM de la máquina.

## Seguridad de la operación

- **Antes de instalar nada comprueba que la red permite recursión.** Pregunta a
  una IP de TEST-NET (`192.0.2.1`), donde no puede existir ningún DNS: si algo
  responde, el puerto 53 saliente está interceptado (dst-nat transparente en el
  router o el ISP) y el script aborta explicando cómo eximir al servidor o usar
  DoT en su lugar. Sin este chequeo, la instalación "terminaría bien" y el
  resolver quedaría roto para la mayor parte de Internet.
- Guarda una copia del `AdGuardHome.yaml` en
  `/root/adguard-unbound-backups/<fecha>/` — tomada **con AdGuard ya parado**,
  porque AdGuard reescribe su YAML desde memoria al apagarse y un snapshot en
  caliente puede ser una versión vieja.
- Valida la configuración de Unbound **combinada con el resto de `conf.d/`**
  (`unbound-checkconf` sin argumento); si no valida, restaura la anterior en vez
  de dejar una configuración rota en disco.
- Verifica la recursión con **dominios poco consultados** (los populares pueden
  responder desde cachés intermedias y esconder una recursión a medias) y el
  DNSSEC con **control positivo y negativo** (firma válida debe traer `ad`,
  firma inválida debe dar SERVFAIL — solo la pareja distingue una validación
  real de un resolver roto, que también da SERVFAIL).
- Tras aplicar el cambio verifica la cadena completa consultando un dominio que
  no puede salir de la caché de AdGuard. **Si AdGuard no vuelve a responder,
  restaura sola la configuración anterior** y te deja el DNS funcionando.
- `--revert-unbound` recupera el último backup y, opcionalmente, desinstala Unbound.

## Detalles que este script resuelve por ti

Cinco cosas que rompen la mayoría de guías y scripts que circulan por ahí:

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
5. **Redes con el puerto 53 interceptado.** Muchas redes (ISPs, hoteles, routers
   con "DNS forzado") redirigen todo el 53 saliente a su propio resolver. Ahí la
   recursión es imposible: el interceptor solo responde consultas iterativas
   desde su caché y devuelve SERVFAIL para el resto, con lo que Unbound resuelve
   los dominios populares y falla los demás — parece un problema de bloqueo o de
   DNSSEC y no lo es. Este script lo detecta antes de instalar y aborta con el
   diagnóstico, en vez de dejarte un resolver a medias.

También enmascara `unbound-resolvconf.service`, que falla en bucle cuando
`/etc/resolv.conf` no es un enlace gestionado por `resolvconf`.

## Requisitos

- Debian o Ubuntu (usa `apt`).
- Ejecutar como `root`.
- Que AdGuard Home escuche en el puerto 53 (o que vayas a instalarlo con este script).

## Notas

- **No expongas el puerto de Unbound a Internet ni a tus clientes.** Solo AdGuard
  debe consultarlo.
- Por defecto se **conserva** el `fallback_dns` como red de seguridad (y si no
  había ninguno, se pone `tls://9.9.9.9`): si Unbound cae, AdGuard sigue
  resolviendo por ahí. Usa `--no-fallback` si prefieres que Unbound sea el único
  camino, asumiendo que **si Unbound cae, la red entera se queda sin DNS**.
- Matiz importante: el fallback actúa cuando el upstream **no responde**. Un
  SERVFAIL sí es una respuesta válida y **no** lo dispara — si Unbound queda
  vivo pero roto (por ejemplo porque alguien empieza a interceptar el 53
  saliente), el fallback no te salva. Para ese caso está el chequeo de
  interceptación: `dig @192.0.2.1 test.com +norec` debe dar *timeout*; si
  responde, la red está interceptando.
- Pasar de un upstream cifrado (DoT/DoH) a resolución recursiva cambia el modelo de
  privacidad: dejas de confiar en un proveedor único, pero las consultas a los
  servidores autoritativos viajan en claro y tu ISP puede verlas.
- La instalación de AdGuard Home descarga el **tarball estático oficial** de
  `static.adguard.com` (con la arquitectura detectada en runtime: amd64, arm64,
  armv7...) y registra el servicio con `AdGuardHome -s install`, sin ejecutar
  scripts remotos. El binario queda en `/opt/AdGuardHome/`.
- Si `systemd-resolved` ocupa el puerto 53, **no se desactiva**: se le quita solo
  el stub (`DNSStubListener=no` vía drop-in en `/etc/systemd/resolved.conf.d/`)
  y `/etc/resolv.conf` pasa a apuntar a `/run/systemd/resolve/resolv.conf`, de
  modo que el host conserva su DNS de siempre (el del DHCP) en todo momento.

## Licencia

MIT. Ver [LICENSE](LICENSE).
