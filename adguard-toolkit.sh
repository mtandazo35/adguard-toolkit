#!/usr/bin/env bash
#
# adguard-toolkit.sh - Instalador / mejorador independiente para AdGuard Home + Unbound
#
#   * Si AdGuard Home NO está instalado -> ofrece instalarlo.
#   * Si AdGuard Home YA está instalado  -> ofrece "mejorarlo" añadiendo Unbound
#                                           como resolver recursivo local.
#
# Uso:
#   ./adguard-toolkit.sh                  menú interactivo
#   ./adguard-toolkit.sh --status         solo diagnóstico, no cambia nada
#   ./adguard-toolkit.sh --unbound        añade/reconfigura Unbound (idempotente)
#   ./adguard-toolkit.sh --install-adguard
#   ./adguard-toolkit.sh --all            instala AdGuard si falta y luego Unbound
#   ./adguard-toolkit.sh --revert-unbound deshace la mejora
#
# Modificadores:
#   --yes | -y          no preguntar nada (para automatizar)
#   --port N            puerto de Unbound (por defecto 5335)
#   --no-fallback       vacía el fallback_dns de AdGuard: Unbound queda como único
#                       camino (si cae, la red entera se queda sin DNS)
#   --keep-fallback     comportamiento por defecto; se acepta por compatibilidad
#
set -Eeuo pipefail

UNBOUND_PORT="5335"
UNBOUND_ADDR="127.0.0.1"
UNBOUND_CONF="/etc/unbound/unbound.conf.d/adguard-home.conf"
BACKUP_ROOT="/root/adguard-unbound-backups"
ASSUME_YES=0
KEEP_FALLBACK=1
ACTION=""

# ---------------------------------------------------------------- utilidades
if [[ -t 1 ]]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'
  C_C=$'\033[1;36m'; C_B=$'\033[1m';    C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_C=""; C_B=""; C_0=""
fi
green(){  printf '%s%s%s\n' "$C_G" "$*" "$C_0"; }
yellow(){ printf '%s%s%s\n' "$C_Y" "$*" "$C_0"; }
red(){    printf '%s%s%s\n' "$C_R" "$*" "$C_0" >&2; }
info(){   printf '%s%s%s\n' "$C_C" "$*" "$C_0"; }
bold(){   printf '%s%s%s\n' "$C_B" "$*" "$C_0"; }

usage(){
  cat <<'USAGE'
Uso:
  adguard-toolkit.sh                  menú interactivo
  adguard-toolkit.sh --status         solo diagnóstico, no cambia nada
  adguard-toolkit.sh --unbound        añade/reconfigura Unbound (idempotente)
  adguard-toolkit.sh --install-adguard
  adguard-toolkit.sh --all            instala AdGuard si falta y luego Unbound
  adguard-toolkit.sh --revert-unbound deshace la mejora

Modificadores:
  --yes | -y      no preguntar nada (para automatizar)
  --port N        puerto de Unbound (por defecto 5335)
  --no-fallback   vacía el fallback_dns de AdGuard: Unbound queda como único
                  camino (si cae, la red entera se queda sin DNS)
USAGE
}

# CONTROLLED=1 marca los fallos que el script ya ha explicado por su cuenta,
# para que la trampa no añada un "ERROR" confuso encima.
CONTROLLED=0
trap '(( CONTROLLED )) || red "ERROR: el script falló en la línea $LINENO (orden: ${BASH_COMMAND})."' ERR

# Espera a que un servidor DNS empiece a responder. AdGuard Home puede tardar
# bastante más de 3 s en servir consultas tras arrancar (carga listas de bloqueo),
# así que hay que reintentar en vez de comprobar una sola vez.
wait_for_dns(){ # wait_for_dns <ip> [puerto] [intentos] [dominio]
  local server="$1" port="${2:-53}" tries="${3:-20}" domain="${4:-cloudflare.com}" i
  for (( i = 0; i < tries; i++ )); do
    if dig +time=2 +tries=1 "@${server}" -p "$port" "$domain" A +short 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# El puerto 53 saliente puede estar interceptado de forma transparente (un
# dst-nat del 53 en el router, práctica común en ISPs y redes corporativas).
# En una red así la recursión es IMPOSIBLE: el interceptor responde a las
# consultas iterativas (RD=0) solo desde su caché y devuelve SERVFAIL para el
# resto, con lo que Unbound parece instalado y "casi" funcionar — resuelve los
# dominios populares y falla el resto. Peor aún: la prueba clásica de DNSSEC
# ("dnssec-failed.org debe dar SERVFAIL") PASA en esa red por el motivo
# equivocado, así que no sirve como validación por sí sola.
#
# Detección: preguntar a una IP de TEST-NET (192.0.2.1, RFC 5737). Ahí no puede
# existir ningún servidor DNS, de modo que CUALQUIER respuesta delata al
# interceptor. Sin interceptación la consulta simplemente agota el tiempo.
hijack53_detected(){ # -> 0 si el 53 saliente está interceptado
  dig @192.0.2.1 hijack-test.invalid A +norec +time=3 +tries=1 2>/dev/null \
    | grep -q 'status:'
}

ask(){ # ask "pregunta" -> 0 si sí
  local q="$1"
  (( ASSUME_YES )) && return 0
  if [[ ! -t 0 ]]; then return 1; fi
  local r
  read -r -p "$(printf '%s%s%s [s/N]: ' "$C_B" "$q" "$C_0")" r || true
  [[ "$r" =~ ^[sSyY]$ ]]
}

need_root(){
  if [[ $EUID -ne 0 ]]; then
    red "Ejecuta este script como root (sudo $0 ...)."
    exit 1
  fi
}

need_apt(){
  if ! command -v apt-get >/dev/null 2>&1; then
    red "Este script está preparado para Debian/Ubuntu (apt)."
    exit 1
  fi
}

need_dig(){
  if ! command -v dig >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y dnsutils
  fi
}

new_backup_dir(){
  local d="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$d"
  printf '%s' "$d"
}

primary_ip(){
  # La IP con la que se sale hacia Internet. `hostname -I` devuelve la primera
  # de la lista, que en hosts con Docker suele ser la de docker0.
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-<ip-del-servidor>}"
}

# ------------------------------------------------------- detección de AdGuard
# Deja en variables: AGH_MODE (native|docker|none), AGH_YAML, AGH_DIR, AGH_SERVICE
detect_adguard(){
  AGH_MODE="none"; AGH_YAML=""; AGH_DIR=""; AGH_SERVICE=""

  # 1) ¿Contenedor Docker?
  if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Image}} {{.Names}}' 2>/dev/null | grep -qi adguard; then
      AGH_MODE="docker"
      return 0
    fi
  fi

  # 2) Instalación nativa: localizar el YAML.
  #    Se incluye /root porque el instalador oficial se ejecuta a menudo desde ahí.
  local f
  for f in \
    /root/AdGuardHome/AdGuardHome.yaml \
    /opt/AdGuardHome/AdGuardHome.yaml \
    /opt/adguardhome/AdGuardHome.yaml \
    /var/lib/AdGuardHome/AdGuardHome.yaml \
    /usr/local/AdGuardHome/AdGuardHome.yaml \
    /etc/AdGuardHome/AdGuardHome.yaml \
    /etc/adguardhome/AdGuardHome.yaml \
    /snap/adguard-home/current/AdGuardHome.yaml
  do
    [[ -f "$f" ]] && { AGH_YAML="$f"; break; }
  done

  # 3) Si sigue sin aparecer, deducirlo del proceso o del servicio en marcha.
  if [[ -z "$AGH_YAML" ]]; then
    local pid
    pid="$(pgrep -x AdGuardHome 2>/dev/null | head -n1 || true)"
    if [[ -n "$pid" ]]; then
      local cwd
      cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
      [[ -n "$cwd" && -f "$cwd/AdGuardHome.yaml" ]] && AGH_YAML="$cwd/AdGuardHome.yaml"
    fi
  fi

  # 4) Último recurso: búsqueda acotada.
  if [[ -z "$AGH_YAML" ]]; then
    AGH_YAML="$(find /root /opt /etc /var/lib /usr/local -maxdepth 4 -type f \
                 -name AdGuardHome.yaml 2>/dev/null | head -n1 || true)"
  fi

  [[ -z "$AGH_YAML" ]] && return 0

  AGH_MODE="native"
  AGH_DIR="$(dirname "$AGH_YAML")"
  local s
  for s in AdGuardHome adguardhome; do
    if systemctl list-unit-files "${s}.service" >/dev/null 2>&1 \
       && systemctl cat "${s}.service" >/dev/null 2>&1; then
      AGH_SERVICE="$s"; break
    fi
  done
  return 0
}

agh_start(){ [[ -n "$AGH_SERVICE" ]] && systemctl start   "$AGH_SERVICE" || true; }
agh_stop(){  [[ -n "$AGH_SERVICE" ]] && systemctl stop    "$AGH_SERVICE" || true; }

agh_restart(){
  if [[ -n "$AGH_SERVICE" ]]; then
    systemctl restart "$AGH_SERVICE"
  elif [[ -x "$AGH_DIR/AdGuardHome" ]]; then
    "$AGH_DIR/AdGuardHome" -s restart >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------- estado
show_status(){
  bold "================= ESTADO ACTUAL ================="
  detect_adguard

  case "$AGH_MODE" in
    native)
      green "AdGuard Home : instalado (nativo)"
      echo  "  config     : $AGH_YAML"
      echo  "  servicio   : ${AGH_SERVICE:-<no encontrado>}"
      if [[ -n "$AGH_SERVICE" ]]; then
        echo "  activo     : $(systemctl is-active "$AGH_SERVICE" 2>/dev/null || echo desconocido)"
      fi
      if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        python3 - "$AGH_YAML" <<'PY' || true
import sys, yaml
d = (yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}).get("dns", {}) or {}
print("  upstream   :", d.get("upstream_dns"))
print("  fallback   :", d.get("fallback_dns"))
print("  modo       :", d.get("upstream_mode"))
PY
      fi
      ;;
    docker) yellow "AdGuard Home : instalado en Docker (este script no edita su YAML)";;
    none)   yellow "AdGuard Home : NO instalado";;
  esac

  echo
  if systemctl list-unit-files unbound.service >/dev/null 2>&1 \
     && command -v unbound >/dev/null 2>&1; then
    green "Unbound      : instalado ($(systemctl is-active unbound 2>/dev/null))"
    ss -lntup 2>/dev/null | grep unbound | sed 's/^/  /' || echo "  (sin sockets)"
  else
    yellow "Unbound      : NO instalado"
  fi

  echo
  echo "Puerto 53:"
  ss -lntup 2>/dev/null | grep -E '(:53[[:space:]]|:53$)' | sed 's/^/  /' \
    || echo "  (nadie escuchando)"

  if command -v dig >/dev/null 2>&1; then
    echo
    if hijack53_detected; then
      red "Red          : el puerto 53 saliente está INTERCEPTADO -> la recursión NO funcionará aquí"
    else
      green "Red          : puerto 53 saliente limpio (la recursión es posible)"
    fi
  fi
  bold "================================================="
}

# -------------------------------------------------- instalación de AdGuard
install_adguard(){
  detect_adguard
  if [[ "$AGH_MODE" != "none" ]]; then
    green "AdGuard Home ya está instalado ($AGH_MODE). No hago nada."
    return 0
  fi

  yellow "Se va a instalar AdGuard Home (tarball oficial + 'AdGuardHome -s install')."
  yellow "Ocupará el puerto 53; si systemd-resolved lo tiene, se libera sin desactivarlo."
  ask "¿Continuar con la instalación de AdGuard Home?" || { yellow "Cancelado."; CONTROLLED=1; return 1; }

  # systemd-resolved es la causa habitual de que :53 esté ocupado. En vez de
  # desactivarlo, se le quita SOLO el stub de 127.0.0.53:53 y se deja que siga
  # gestionando el DNS del host: /etc/resolv.conf pasa a apuntar al fichero con
  # los upstreams reales (los del DHCP/netplan), así el host no pierde salida a
  # Internet en ningún momento. Drop-in en vez de sed sobre resolved.conf:
  # cubre el caso de que la directiva no exista en el fichero y sobrevive a
  # actualizaciones del paquete.
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    yellow "systemd-resolved está activo y su stub ocupa el puerto 53."
    if ask "¿Liberar el puerto 53 (DNSStubListener=no) manteniendo systemd-resolved?"; then
      systemctl stop systemd-resolved
      mkdir -p /etc/systemd/resolved.conf.d
      printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/99-adguard.conf
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      systemctl start systemd-resolved
      green "Puerto 53 libre; systemd-resolved sigue gestionando el DNS del host."
    fi
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates

  # Tarball estático oficial en vez del install.sh remoto: mismo resultado
  # ('AdGuardHome -s install' registra y arranca el servicio systemd), pero sin
  # ejecutar un script descargado y con la arquitectura detectada en runtime en
  # vez de asumir amd64. El -f de curl es importante: sin él, un 404 guardaría
  # la página de error y tar fallaría con un mensaje que no apunta a la causa.
  local arch
  case "$(uname -m)" in
    x86_64)         arch="amd64";;
    aarch64|arm64)  arch="arm64";;
    armv7l)         arch="armv7";;
    armv6l)         arch="armv6";;
    i486|i586|i686) arch="386";;
    *) red "Arquitectura no soportada: $(uname -m)"; CONTROLLED=1; return 1;;
  esac
  info "==> Descargando AdGuard Home (linux_${arch})..."
  local tarball
  tarball="$(mktemp /tmp/adguardhome.XXXXXX.tar.gz)"
  curl -fsSL "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${arch}.tar.gz" \
    -o "$tarball"
  tar -xzf "$tarball" -C /opt
  rm -f "$tarball"

  info "==> Registrando el servicio (AdGuardHome -s install)..."
  /opt/AdGuardHome/AdGuardHome -s install

  sleep 3
  detect_adguard
  if [[ "$AGH_MODE" == "none" ]]; then
    # Nota: recién instalado, AdGuardHome.yaml no existe hasta completar el
    # asistente web, así que aquí AGH_MODE seguirá siendo "none" aunque la
    # instalación haya ido bien. Comprobar el binario/servicio, no el YAML.
    if ! systemctl list-unit-files AdGuardHome.service >/dev/null 2>&1 \
       && ! pgrep -x AdGuardHome >/dev/null 2>&1; then
      red "La instalación de AdGuard Home no se pudo verificar."
      CONTROLLED=1
      return 1
    fi
  fi

  green "AdGuard Home instalado."
  bold "Abre http://$(primary_ip):3000 para completar el asistente inicial."
  yellow "Termina ese asistente ANTES de aplicar la mejora de Unbound: hasta"
  yellow "entonces no existe AdGuardHome.yaml, y al terminarlo el asistente"
  yellow "escribiría su propio upstream encima de cualquier cambio previo."
}

# ---------------------------------------------------- instalación de Unbound
install_unbound(){
  detect_adguard

  if [[ "$AGH_MODE" == "none" ]]; then
    yellow "No detecto AdGuard Home. Unbound se instalará igualmente en ${UNBOUND_ADDR}:${UNBOUND_PORT},"
    yellow "pero tendrás que apuntar tu DNS a él manualmente."
    ask "¿Continuar de todas formas?" || { yellow "Cancelado."; CONTROLLED=1; return 1; }
  fi

  if [[ "$AGH_MODE" == "docker" ]]; then
    yellow "AdGuard Home corre en Docker."
    yellow "Un contenedor NO alcanza 127.0.0.1 del host: tendrás que usar la IP del host"
    yellow "(o red 'host') y poner el upstream a mano en la interfaz web."
  fi

  # Antes de tocar nada: ¿esta red permite recursión? Si el 53 saliente está
  # interceptado, TODO lo demás saldría "bien" (instalación, arranque, incluso
  # la prueba de DNSSEC) y el resolver quedaría roto para media Internet.
  info "==> Comprobando que la red permite resolución recursiva..."
  need_dig
  if hijack53_detected; then
    red "El puerto 53 saliente está INTERCEPTADO: la IP de prueba 192.0.2.1"
    red "(TEST-NET, ahí no puede existir ningún DNS) ha respondido."
    red ""
    red "La resolución recursiva NO puede funcionar en esta red: Unbound daría"
    red "SERVFAIL en la mayoría de dominios (los populares sí resolverían, desde"
    red "la caché del interceptor, lo que hace el fallo aún más confuso)."
    red ""
    red "Opciones:"
    red "  1) Localiza la redirección (p. ej. un dst-nat del puerto 53 en el"
    red "     router/MikroTik) y exime la IP de este servidor, UDP y TCP."
    red "  2) O usa upstreams cifrados en AdGuard (tls://1.1.1.1, tls://9.9.9.9...)"
    red "     en lugar de recursión: el 853 no suele estar interceptado."
    CONTROLLED=1
    return 1
  fi
  green "Puerto 53 saliente limpio: la recursión es posible."

  local BACKUP_DIR; BACKUP_DIR="$(new_backup_dir)"

  info "==> Detectando recursos..."
  local CPU THREADS MEM_MB MSG_CACHE RRSET_CACHE
  CPU="$(nproc)"; THREADS="$CPU"
  (( THREADS > 8 )) && THREADS=8
  (( THREADS < 1 )) && THREADS=1
  MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  if   (( MEM_MB >= 8192 )); then MSG_CACHE="256m"; RRSET_CACHE="512m"
  elif (( MEM_MB >= 4096 )); then MSG_CACHE="128m"; RRSET_CACHE="256m"
  elif (( MEM_MB >= 2048 )); then MSG_CACHE="64m";  RRSET_CACHE="128m"
  else                            MSG_CACHE="32m";  RRSET_CACHE="64m"
  fi
  printf "CPU: %s | hilos: %s | RAM: %s MB | caché: %s/%s\n" \
    "$CPU" "$THREADS" "$MEM_MB" "$MSG_CACHE" "$RRSET_CACHE"

  # IMPORTANTE: el postinst de Debian arranca unbound en 127.0.0.1:53, que choca
  # con AdGuard Home. Sembramos el puerto antes de instalar para que no falle.
  info "==> Fijando puerto de Unbound antes de instalar (evita choque con :53)..."
  mkdir -p /etc/unbound/unbound.conf.d
  [[ -f "$UNBOUND_CONF" ]] && cp -a "$UNBOUND_CONF" "$BACKUP_DIR/" || true
  printf 'server:\n    interface: %s\n    port: %s\n' \
    "$UNBOUND_ADDR" "$UNBOUND_PORT" > "$UNBOUND_CONF"

  info "==> Instalando paquetes..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y unbound unbound-anchor dnsutils python3-yaml ca-certificates

  info "==> Preparando trust anchor DNSSEC..."
  install -d -o unbound -g unbound /var/lib/unbound
  command -v unbound-anchor >/dev/null 2>&1 && \
    unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
  chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
  chmod 0644 /var/lib/unbound/root.key 2>/dev/null || true

  info "==> Escribiendo configuración de Unbound..."
  # NOTA: aquí NO se declara auto-trust-anchor-file. Debian ya lo define en
  # /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf apuntando al
  # mismo root.key; duplicarlo hace que unbound aborte con
  # "error: trust anchor presented twice".
  cat > "$UNBOUND_CONF" <<EOF
server:
    # Solo el propio host (AdGuard Home) puede consultar este resolver.
    interface: ${UNBOUND_ADDR}
    port: ${UNBOUND_PORT}
    access-control: 127.0.0.0/8 allow

    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    num-threads: ${THREADS}
    msg-cache-size: ${MSG_CACHE}
    rrset-cache-size: ${RRSET_CACHE}
    edns-buffer-size: 1232
    max-udp-size: 1232

    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    cache-min-ttl: 0
    cache-max-ttl: 86400

    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    qname-minimisation-strict: no
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    aggressive-nsec: yes
    unwanted-reply-threshold: 10000000

    verbosity: 1
    use-syslog: yes
EOF

  info "==> Validando la configuración completa..."
  # Sin argumento, unbound-checkconf valida unbound.conf CON todos sus includes
  # (el resto de conf.d/). Pasarle solo este fichero validaría el fichero
  # aislado y no detectaría conflictos entre ficheros — justo la clase de error
  # del trust anchor duplicado.
  if ! unbound-checkconf; then
    red "La configuración combinada de Unbound no valida (ver error de arriba)."
    if [[ -f "$BACKUP_DIR/$(basename "$UNBOUND_CONF")" ]]; then
      cp -a "$BACKUP_DIR/$(basename "$UNBOUND_CONF")" "$UNBOUND_CONF"
      red "Se restauró la configuración anterior de $UNBOUND_CONF."
    else
      rm -f "$UNBOUND_CONF"
      red "Se eliminó $UNBOUND_CONF para no dejar una configuración rota."
    fi
    CONTROLLED=1
    return 1
  fi

  # unbound-resolvconf reescribe /etc/resolv.conf vía resolvconf. Si resolv.conf
  # no es un symlink gestionado, falla en bucle y solo mete ruido.
  if systemctl list-unit-files unbound-resolvconf.service >/dev/null 2>&1; then
    systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
    systemctl mask unbound-resolvconf.service >/dev/null 2>&1 || true
  fi

  systemctl enable unbound >/dev/null
  systemctl reset-failed unbound >/dev/null 2>&1 || true
  systemctl restart unbound
  sleep 2

  if ! systemctl is-active --quiet unbound; then
    red "Unbound no arrancó. Últimas líneas del log:"
    journalctl -u unbound -n 40 --no-pager
    CONTROLLED=1
    return 1
  fi
  if ! ss -lntup 2>/dev/null | grep -q "127.0.0.1:${UNBOUND_PORT}"; then
    red "Unbound no está escuchando en 127.0.0.1:${UNBOUND_PORT}."
    CONTROLLED=1
    return 1
  fi

  info "==> Probando resolución recursiva..."
  if ! wait_for_dns 127.0.0.1 "$UNBOUND_PORT" 5; then
    red "Unbound no resuelve. Log:"
    journalctl -u unbound -n 40 --no-pager
    CONTROLLED=1
    return 1
  fi

  # Los dominios populares pueden salir de cualquier caché intermedia y esconder
  # una recursión a medias; los poco consultados obligan a recursar de verdad.
  local d fails=0
  for d in nlnetlabs.nl suckless.org riken.jp; do
    if ! dig +time=8 +tries=1 @127.0.0.1 -p "$UNBOUND_PORT" "$d" A +short 2>/dev/null | grep -q .; then
      yellow "  control $d: sin respuesta"
      fails=$((fails+1))
    fi
  done
  if (( fails >= 2 )); then
    red "La recursión no funciona de verdad: fallan $fails de 3 dominios de control"
    red "poco consultados (los populares pueden responder desde cachés intermedias)."
    journalctl -u unbound -n 40 --no-pager
    CONTROLLED=1
    return 1
  fi
  green "Resolución recursiva por Unbound: OK"

  if ip -6 route show default 2>/dev/null | grep -q .; then
    if dig +time=5 +tries=1 @127.0.0.1 -p "$UNBOUND_PORT" google.com AAAA +short | grep -q ':'; then
      green "Resolución IPv6 por Unbound: OK"
    else
      yellow "Hay ruta IPv6 pero la prueba AAAA no respondió; IPv4 sigue bien."
    fi
  fi

  # DNSSEC con control positivo Y negativo. Solo la pareja distingue una
  # validación real de una recursión rota: un resolver roto también da SERVFAIL
  # en el dominio mal firmado, y "pasaría" la prueba negativa por sí sola.
  local sec_ok=0 sec_bad=0
  dig @127.0.0.1 -p "$UNBOUND_PORT" +time=8 sigok.verteiltesysteme.net A 2>/dev/null \
    | grep -Eq 'flags:[^;]* ad[ ;]' && sec_ok=1
  dig @127.0.0.1 -p "$UNBOUND_PORT" +time=8 dnssec-failed.org A 2>/dev/null \
    | grep -q 'SERVFAIL' && sec_bad=1
  if (( sec_ok && sec_bad )); then
    green "Validación DNSSEC: OK (firma válida con 'ad', firma inválida rechazada)"
  elif (( sec_bad )); then
    yellow "dnssec-failed.org da SERVFAIL pero el control positivo no trae 'ad';"
    yellow "revisa el trust anchor (/var/lib/unbound/root.key)."
  else
    yellow "La validación DNSSEC no se pudo confirmar; revisa el trust anchor."
  fi

  # ------------------------------------------------ enganchar con AdGuard
  if [[ "$AGH_MODE" != "native" ]]; then
    yellow "No puedo editar la configuración de AdGuard automáticamente."
    yellow "Pon en Settings > DNS settings > Upstream DNS servers SOLO:"
    printf "    %s:%s\n" "$UNBOUND_ADDR" "$UNBOUND_PORT"
    return 0
  fi

  info "==> Configurando AdGuard Home: $AGH_YAML"

  # Parar ANTES de copiar: AdGuard reescribe su YAML desde memoria al apagarse,
  # así que un snapshot tomado con el servicio vivo puede ser una versión vieja
  # si el administrador tocó algo por la interfaz web desde el último volcado.
  local WAS_ACTIVE=0
  if [[ -n "$AGH_SERVICE" ]] && systemctl is-active --quiet "$AGH_SERVICE"; then
    WAS_ACTIVE=1
    agh_stop
    sleep 1
  fi

  local SNAP="$BACKUP_DIR/AdGuardHome.yaml.before-unbound"
  cp -a "$AGH_YAML" "$SNAP"

  python3 - "$AGH_YAML" "${UNBOUND_ADDR}:${UNBOUND_PORT}" "$KEEP_FALLBACK" <<'PY'
import sys, yaml
path, upstream, keep_fb = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}
dns = cfg.setdefault("dns", {})
# upstream_dns_file tiene prioridad sobre upstream_dns: hay que vaciarlo.
dns["upstream_dns_file"] = ""
dns["upstream_dns"] = [upstream]
if keep_fb:
    # Red de seguridad si Unbound cae. Cifrada (DoT) para no depender del 53
    # en claro. Solo se añade si no había ya un fallback configurado.
    if not dns.get("fallback_dns"):
        dns["fallback_dns"] = ["tls://9.9.9.9"]
else:
    dns["fallback_dns"] = []
with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
PY

  (( WAS_ACTIVE )) && agh_start || agh_restart

  # Verificación con reversión automática si el DNS se rompe. Se consulta un
  # dominio poco popular: uno popular podría responder desde la caché del propio
  # AdGuard sin atravesar el upstream nuevo, que es justo lo que hay que probar.
  info "==> Esperando a que AdGuard responda a través de Unbound (hasta 40 s)..."
  if wait_for_dns 127.0.0.1 53 20 nlnetlabs.nl; then
    green "Cadena AdGuard -> Unbound -> Internet: OK"
  else
    red "AdGuard no responde tras el cambio. Restaurando la configuración anterior..."
    agh_stop
    cp -a "$SNAP" "$AGH_YAML"
    agh_start
    wait_for_dns 127.0.0.1 53 || true
    red "Configuración de AdGuard restaurada desde $SNAP"
    red "Unbound queda instalado y funcionando en ${UNBOUND_ADDR}:${UNBOUND_PORT}, pero AdGuard NO lo usa."
    CONTROLLED=1
    return 1
  fi

  echo
  green "=========================================================="
  green " MEJORA APLICADA"
  green "=========================================================="
  echo "Unbound        : ${UNBOUND_ADDR}:${UNBOUND_PORT} (recursivo, DNSSEC)"
  echo "AdGuard Home   : sigue sirviendo el puerto 53 a tus clientes"
  echo "Backup         : $BACKUP_DIR"
  if (( KEEP_FALLBACK )); then
    echo "fallback_dns   : conservado (red de seguridad si Unbound cae)"
    yellow "Nota: el fallback actúa cuando Unbound NO RESPONDE. Un SERVFAIL sí es"
    yellow "respuesta y no lo dispara (p. ej. si mañana algo intercepta el 53)."
  else
    yellow "fallback_dns   : vaciado (--no-fallback) -> si Unbound cae, la red se queda sin DNS."
  fi
  echo
  echo "No expongas el puerto ${UNBOUND_PORT} a Internet ni a los clientes."
}

# --------------------------------------------- AdGuard + Unbound de una vez
install_all(){
  install_adguard || true
  detect_adguard
  if [[ "$AGH_MODE" != "native" ]]; then
    # Recién instalado, el YAML no existe hasta completar el asistente web.
    # Configurar Unbound ahora sería inútil: al terminar el asistente, AdGuard
    # escribiría su propio upstream encima y la mejora quedaría deshecha en
    # silencio. Mejor parar aquí con instrucciones claras.
    echo
    yellow "AdGuard Home aún no tiene configuración (falta completar el asistente web)."
    bold   "1) Abre http://$(primary_ip):3000 y completa el asistente."
    bold   "2) Después ejecuta:  adguard-toolkit.sh --unbound"
    return 0
  fi
  install_unbound
}

# ------------------------------------------------------------- revertir
revert_unbound(){
  detect_adguard
  local SNAP=""
  if [[ -d "$BACKUP_ROOT" ]]; then
    SNAP="$(ls -1dt "$BACKUP_ROOT"/*/AdGuardHome.yaml.before-unbound 2>/dev/null | head -n1 || true)"
  fi

  if [[ "$AGH_MODE" == "native" ]]; then
    if [[ -n "$SNAP" ]]; then
      info "Restaurando AdGuard desde: $SNAP"
      ask "¿Restaurar la configuración de AdGuard anterior a Unbound?" || { yellow "Cancelado."; CONTROLLED=1; return 1; }
      agh_stop
      cp -a "$AGH_YAML" "${AGH_YAML}.before-revert"
      cp -a "$SNAP" "$AGH_YAML"
      agh_start
      wait_for_dns 127.0.0.1 53 || true
      green "AdGuard restaurado (copia del estado actual en ${AGH_YAML}.before-revert)."
    else
      yellow "No encontré backup previo. Pongo upstreams públicos cifrados por seguridad."
      ask "¿Aplicar tls://1.1.1.1 y tls://1.0.0.1 como upstream?" || { yellow "Cancelado."; CONTROLLED=1; return 1; }
      agh_stop
      python3 - "$AGH_YAML" <<'PY'
import sys, yaml
p = sys.argv[1]
cfg = yaml.safe_load(open(p, encoding="utf-8")) or {}
dns = cfg.setdefault("dns", {})
dns["upstream_dns"] = ["tls://1.1.1.1", "tls://1.0.0.1"]
dns["upstream_dns_file"] = ""
yaml.safe_dump(cfg, open(p, "w", encoding="utf-8"), sort_keys=False, allow_unicode=True)
PY
      agh_start
      wait_for_dns 127.0.0.1 53 || true
      green "Upstreams públicos aplicados."
    fi
  fi

  if ask "¿Desinstalar también el paquete unbound?"; then
    systemctl disable --now unbound >/dev/null 2>&1 || true
    systemctl unmask unbound-resolvconf.service >/dev/null 2>&1 || true
    rm -f "$UNBOUND_CONF"
    apt-get purge -y unbound unbound-anchor >/dev/null
    apt-get autoremove -y >/dev/null
    green "Unbound desinstalado."
  else
    # Ya nadie lo usa: pararlo y deshabilitarlo, pero conservarlo instalado.
    # unbound-resolvconf se queda enmascarado a propósito mientras el paquete
    # siga presente (reactivarlo volvería a pelearse con /etc/resolv.conf).
    systemctl disable --now unbound >/dev/null 2>&1 || true
    yellow "Unbound queda instalado pero parado y deshabilitado; AdGuard ya no lo usa."
  fi

  if wait_for_dns 127.0.0.1 53; then
    green "DNS operativo tras la reversión."
  else
    red "Atención: el DNS no responde. Revisa 'systemctl status AdGuardHome'."
  fi
}

# ---------------------------------------------------------------- menú
menu(){
  detect_adguard
  echo
  bold "============================================================"
  bold "  AdGuard Home + Unbound - instalador / mejorador"
  bold "============================================================"
  case "$AGH_MODE" in
    native) green "Detectado: AdGuard Home instalado en $AGH_DIR";;
    docker) yellow "Detectado: AdGuard Home en Docker";;
    none)   yellow "Detectado: AdGuard Home NO instalado";;
  esac
  if command -v unbound >/dev/null 2>&1; then
    green "Detectado: Unbound instalado ($(systemctl is-active unbound 2>/dev/null))"
  else
    yellow "Detectado: Unbound no instalado"
  fi
  echo
  echo "  1) Ver estado detallado"
  if [[ "$AGH_MODE" == "none" ]]; then
    echo "  2) Instalar AdGuard Home"
    echo "  3) Instalar AdGuard Home y luego añadir Unbound"
  else
    echo "  2) MEJORAR: añadir Unbound como resolver recursivo"
    echo "  3) Revertir la mejora de Unbound"
  fi
  echo "  0) Salir"
  echo
  local opt
  read -r -p "Opción: " opt || true
  case "${opt:-0}" in
    1) show_status;;
    2) if [[ "$AGH_MODE" == "none" ]]; then install_adguard; else install_unbound; fi;;
    3) if [[ "$AGH_MODE" == "none" ]]; then install_all; else revert_unbound; fi;;
    *) echo "Saliendo.";;
  esac
}

# ---------------------------------------------------------------- argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)          ACTION="status";;
    --unbound)         ACTION="unbound";;
    --install-adguard) ACTION="adguard";;
    --all)             ACTION="all";;
    --revert-unbound)  ACTION="revert";;
    --yes|-y)          ASSUME_YES=1;;
    --no-fallback)     KEEP_FALLBACK=0;;
    --keep-fallback)   KEEP_FALLBACK=1;;  # comportamiento por defecto; compat
    --port)            shift || true; UNBOUND_PORT="${1:-}";;
    -h|--help)         usage; exit 0;;
    *) red "Opción desconocida: $1"; usage; exit 1;;
  esac
  shift || true
done

if ! [[ "$UNBOUND_PORT" =~ ^[0-9]+$ ]] || (( UNBOUND_PORT < 1 || UNBOUND_PORT > 65535 )); then
  red "Puerto inválido: $UNBOUND_PORT"; exit 1
fi
if (( UNBOUND_PORT == 53 )); then
  red "El puerto 53 es el de AdGuard Home. Elige otro (por defecto 5335)."; exit 1
fi

need_root
need_apt

case "$ACTION" in
  status)  show_status;;
  unbound) install_unbound;;
  adguard) install_adguard;;
  all)     install_all;;
  revert)  revert_unbound;;
  "")      if [[ -t 0 ]]; then menu; else show_status; fi;;
esac
