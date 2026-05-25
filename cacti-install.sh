#!/usr/bin/env bash
# =============================================================================
# Cacti 1.2.x + Spine 1.2.30 Automated Installer
# Compatible: Debian 11/12, Ubuntu 20.04/22.04/24.04
# Usage: sudo bash cacti-install.sh [--update] [--plugin <name>]
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CARREGAR CONFIGURAÇÃO CENTRAL -------------------------------------------
# Lê cacti-deploy.conf se existir (tem prioridade sobre os defaults abaixo)
CONF_FILE="${SCRIPT_DIR}/cacti-deploy.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# --- CONFIGURAÇÃO PRINCIPAL --------------------------------------------------
# Valores definidos no .conf têm prioridade; caso contrário usa os defaults
CACTI_VERSION="${CACTI_VERSION:-1.2.30}"
SPINE_VERSION="${SPINE_VERSION:-1.2.30}"
CACTI_DB_NAME="${CACTI_DB_NAME:-cacti}"
CACTI_DB_USER="${CACTI_DB_USER:-cactiuser}"
CACTI_DB_PASS="${CACTI_DB_PASS:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c20)}"
CACTI_ADMIN_PASS="${CACTI_ADMIN_PASS:-admin}"
PHP_TIMEZONE="${PHP_TIMEZONE:-Africa/Luanda}"
CACTI_WEB_DIR="/var/www/html/cacti"
SPINE_DIR="/usr/local/spine"
LOG_FILE="/var/log/cacti-install.log"
CONFIG_FILE="${SCRIPT_DIR}/.cacti-install.conf"

# Repositórios dos plugins
declare -A PLUGIN_REPOS=(
  [thold]="https://github.com/Cacti/plugin_thold.git"
  [syslog]="https://github.com/Cacti/plugin_syslog.git"
  [maint]="https://github.com/Cacti/plugin_maint.git"
  [monitor]="https://github.com/Cacti/plugin_monitor.git"
  [hmib]="https://github.com/Cacti/plugin_hmib.git"
  [webseer]="https://github.com/Cacti/plugin_webseer.git"
  [gexport]="https://github.com/Cacti/plugin_gexport.git"
  [intropage]="https://github.com/Cacti/plugin_intropage.git"
  [audit]="https://github.com/Cacti/plugin_audit.git"
  [routerconfigs]="https://github.com/Cacti/plugin_routerconfigs.git"
  [weathermap]="https://github.com/Cacti/plugin_weathermap.git"
  [flowview]="https://github.com/Cacti/plugin_flowview.git"
)

# Branches dos plugins — lidos do .conf se definidos, senão "develop"
declare -A PLUGIN_BRANCHES=(
  [thold]="${PLUGIN_BRANCH_THOLD:-develop}"
  [syslog]="${PLUGIN_BRANCH_SYSLOG:-develop}"
  [maint]="${PLUGIN_BRANCH_MAINT:-develop}"
  [monitor]="${PLUGIN_BRANCH_MONITOR:-develop}"
  [hmib]="${PLUGIN_BRANCH_HMIB:-develop}"
  [webseer]="${PLUGIN_BRANCH_WEBSEER:-develop}"
  [gexport]="${PLUGIN_BRANCH_GEXPORT:-develop}"
  [intropage]="${PLUGIN_BRANCH_INTROPAGE:-develop}"
  [audit]="${PLUGIN_BRANCH_AUDIT:-develop}"
  [routerconfigs]="${PLUGIN_BRANCH_ROUTERCONFIGS:-develop}"
  [weathermap]="${PLUGIN_BRANCH_WEATHERMAP:-develop}"
  [flowview]="${PLUGIN_BRANCH_FLOWVIEW:-develop}"
)

# --- CORES -------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# --- FUNÇÕES UTILITÁRIAS -----------------------------------------------------
log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
success() { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            log "STEP: $*"; }

load_config() {
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" && info "Configuração carregada: $CONFIG_FILE"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# Gerado automaticamente em $(date)
CACTI_DB_PASS="${CACTI_DB_PASS}"
CACTI_ADMIN_PASS="${CACTI_ADMIN_PASS}"
CACTI_DB_NAME="${CACTI_DB_NAME}"
CACTI_DB_USER="${CACTI_DB_USER}"
EOF
  chmod 600 "$CONFIG_FILE"
  info "Configuração salva em $CONFIG_FILE"
}

check_root() {
  [[ $EUID -eq 0 ]] || error "Execute como root: sudo bash $0"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
    OS_CODENAME="${VERSION_CODENAME:-}"
    info "Sistema: $PRETTY_NAME"
  else
    error "Sistema operativo não suportado"
  fi
  case "$OS_ID" in
    debian|ubuntu) ;;
    *) error "Apenas Debian/Ubuntu são suportados. Detectado: $OS_ID" ;;
  esac
}

check_proxmox_vm() {
  if systemd-detect-virt -q 2>/dev/null; then
    VIRT=$(systemd-detect-virt 2>/dev/null || echo "desconhecido")
    info "Virtualização detectada: $VIRT"
  fi
}

# --- DEPENDÊNCIAS ------------------------------------------------------------
install_dependencies() {
  step "Instalando dependências do sistema"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  PKGS=(
    apache2 libapache2-mod-php
    mariadb-server mariadb-client
    php php-mysql php-snmp php-xml php-mbstring php-gd php-curl php-zip php-ldap
    php-gmp php-intl php-json php-common php-cli
    rrdtool librrds-perl
    snmp snmpd snmp-mibs-downloader
    git curl wget unzip
    build-essential autoconf automake libtool pkg-config
    libmariadb-dev libmariadb-dev-compat
    libsnmp-dev libssl-dev
    dos2unix net-tools cron
    # Para Flowview
    nfdump fprobe
    # Para Weathermap
    php-gd
    # Para Routerconfigs
    expect sshpass
  )

  apt-get install -y --no-install-recommends "${PKGS[@]}" 2>&1 | tee -a "$LOG_FILE" | grep -E "^(Get:|Inst |Setting)" || true
  success "Dependências instaladas"

  # PHP timezone
  PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $NF}')
  if [[ -f "$PHP_INI" ]]; then
    sed -i "s|;date.timezone =|date.timezone = ${PHP_TIMEZONE}|g" "$PHP_INI"
    # Também para Apache
    for ini in /etc/php/*/apache2/php.ini; do
      [[ -f "$ini" ]] && sed -i "s|;date.timezone =|date.timezone = ${PHP_TIMEZONE}|g" "$ini"
    done
    success "Timezone PHP configurado"
  fi
}

# --- MARIADB -----------------------------------------------------------------
configure_mariadb() {
  step "Configurando MariaDB"

  systemctl enable mariadb --quiet
  systemctl start mariadb

  # Configurações de performance para Cacti
  cat > /etc/mysql/mariadb.conf.d/99-cacti.cnf <<'MYCNF'
[mysqld]
# Cacti optimizations
collation-server         = utf8mb4_unicode_ci
character-set-server     = utf8mb4
max_heap_table_size      = 128M
tmp_table_size           = 128M
join_buffer_size         = 128M
innodb_file_per_table    = ON
innodb_buffer_pool_size  = 512M
innodb_doublewrite       = OFF
innodb_flush_log_at_timeout = 3
innodb_read_io_threads   = 32
innodb_write_io_threads  = 16
innodb_io_capacity       = 5000
innodb_io_capacity_max   = 10000
innodb_log_buffer_size   = 64M
max_connections          = 300
query_cache_type         = OFF
query_cache_size         = 0
log_error                = /var/log/mysql/error.log
slow_query_log           = 1
slow_query_log_file      = /var/log/mysql/slow.log
long_query_time          = 2

[client]
default-character-set    = utf8mb4
MYCNF

  systemctl restart mariadb

  # Criar banco e utilizador
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${CACTI_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${CACTI_DB_USER}'@'localhost' IDENTIFIED BY '${CACTI_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${CACTI_DB_NAME}\`.* TO '${CACTI_DB_USER}'@'localhost';
CREATE DATABASE IF NOT EXISTS \`${CACTI_DB_NAME}_syslog\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${CACTI_DB_NAME}_syslog\`.* TO '${CACTI_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  success "MariaDB configurado — DB: ${CACTI_DB_NAME}, User: ${CACTI_DB_USER}"
}

# --- CACTI -------------------------------------------------------------------
install_cacti() {
  step "Instalando Cacti ${CACTI_VERSION}"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  trap "rm -rf $TMPDIR" EXIT

  # Download
  local URL="https://github.com/Cacti/cacti/releases/download/release/${CACTI_VERSION}/cacti-${CACTI_VERSION}.tar.gz"
  info "Download Cacti de $URL"
  wget -q --show-progress -O "${TMPDIR}/cacti.tar.gz" "$URL" || \
    error "Falha ao baixar Cacti ${CACTI_VERSION}"

  # Extrair
  tar -xzf "${TMPDIR}/cacti.tar.gz" -C "${TMPDIR}"
  local CACTI_SRC="${TMPDIR}/cacti-${CACTI_VERSION}"

  # Instalar
  [[ -d "$CACTI_WEB_DIR" ]] && mv "$CACTI_WEB_DIR" "${CACTI_WEB_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  cp -r "$CACTI_SRC" "$CACTI_WEB_DIR"

  # config.php
  cat > "${CACTI_WEB_DIR}/include/config.php" <<PHP
<?php
\$database_type     = 'mysql';
\$database_default  = '${CACTI_DB_NAME}';
\$database_hostname = 'localhost';
\$database_username = '${CACTI_DB_USER}';
\$database_password = '${CACTI_DB_PASS}';
\$database_port     = '3306';
\$database_ssl      = false;
\$database_ssl_key  = '';
\$database_ssl_cert = '';
\$database_ssl_ca   = '';
\$url_path          = '/cacti/';
\$poller_id         = 1;
PHP

  # Importar schema
  info "Importando schema do banco..."
  mysql -u root "${CACTI_DB_NAME}" < "${CACTI_WEB_DIR}/cacti.sql"

  # timezone table para MariaDB
  mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql 2>/dev/null || true
  mysql -u root <<SQL
GRANT SELECT ON mysql.time_zone_name TO '${CACTI_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Permissões
  chown -R www-data:www-data "$CACTI_WEB_DIR"
  chmod -R 755 "$CACTI_WEB_DIR"
  chmod 750 "${CACTI_WEB_DIR}/include/config.php"

  # Criar diretórios de log/cache
  mkdir -p "${CACTI_WEB_DIR}/log" "${CACTI_WEB_DIR}/cache/boost" \
           "${CACTI_WEB_DIR}/cache/mibcache" "${CACTI_WEB_DIR}/cache/realtime" \
           "${CACTI_WEB_DIR}/cache/spikekill"
  chown -R www-data:www-data "${CACTI_WEB_DIR}/log" "${CACTI_WEB_DIR}/cache"

  success "Cacti ${CACTI_VERSION} instalado em ${CACTI_WEB_DIR}"
}

# --- SPINE -------------------------------------------------------------------
install_spine() {
  step "Compilando e instalando Spine ${SPINE_VERSION}"

  local TMPDIR
  TMPDIR=$(mktemp -d)

  local URL="https://github.com/Cacti/spine/releases/download/release/${SPINE_VERSION}/spine-${SPINE_VERSION}.tar.gz"
  info "Download Spine de $URL"
  wget -q --show-progress -O "${TMPDIR}/spine.tar.gz" "$URL" || \
    error "Falha ao baixar Spine ${SPINE_VERSION}"

  tar -xzf "${TMPDIR}/spine.tar.gz" -C "${TMPDIR}"
  cd "${TMPDIR}/spine-${SPINE_VERSION}"

  ./configure --prefix="${SPINE_DIR}" 2>&1 | tail -5
  make -j"$(nproc)" 2>&1 | tail -5
  make install

  # Config do Spine
  cat > /usr/local/spine/etc/spine.conf <<SPCONF
DB_Host       localhost
DB_Database   ${CACTI_DB_NAME}
DB_User       ${CACTI_DB_USER}
DB_Pass       ${CACTI_DB_PASS}
DB_Port       3306
RDB_On        0
Path_Spider   ${SPINE_DIR}/bin/spine
Cacti_Log     ${CACTI_WEB_DIR}/log/cacti.log
SPCONF

  # Setuid para o Spine poder abrir raw sockets
  chown root:www-data "${SPINE_DIR}/bin/spine"
  chmod u+s "${SPINE_DIR}/bin/spine"

  cd /
  rm -rf "$TMPDIR"
  success "Spine ${SPINE_VERSION} instalado em ${SPINE_DIR}"
}

# --- APACHE ------------------------------------------------------------------
configure_apache() {
  step "Configurando Apache"

  a2enmod rewrite headers ssl php* 2>/dev/null || true

  cat > /etc/apache2/conf-available/cacti.conf <<'APCONF'
Alias /cacti /var/www/html/cacti

<Directory /var/www/html/cacti>
    Options +FollowSymLinks
    AllowOverride All
    Require all granted

    <IfModule mod_php.c>
        php_flag  magic_quotes_gpc       Off
        php_flag  short_open_tag         On
        php_flag  register_globals       Off
        php_flag  register_argc_argv     On
        php_flag  track_vars             On
        php_value include_path           .
        php_admin_flag allow_url_fopen   On
        php_admin_value upload_tmp_dir   /tmp
        php_admin_value open_basedir     /var/www/html/cacti:/tmp:/usr/share/php
    </IfModule>
</Directory>
APCONF

  a2enconf cacti

  # .htaccess para o Cacti
  cat > "${CACTI_WEB_DIR}/.htaccess" <<'HTA'
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteBase /cacti/
</IfModule>
Options -Indexes
HTA

  systemctl enable apache2 --quiet
  systemctl restart apache2
  success "Apache configurado"
}

# --- CRON --------------------------------------------------------------------
configure_cron() {
  step "Configurando Cron do Cacti"

  cat > /etc/cron.d/cacti <<'CRONTAB'
# Cacti poller - a cada 5 minutos
*/5 * * * * www-data php /var/www/html/cacti/poller.php --force >> /var/log/cacti/poller.log 2>&1

# Cacti boost - a cada hora
0 * * * * www-data php /var/www/html/cacti/poller_boost.php --force >> /var/log/cacti/boost.log 2>&1

# Cacti spikekill diário
0 3 * * * www-data php /var/www/html/cacti/poller_spikekill.php >> /var/log/cacti/spikekill.log 2>&1
CRONTAB

  mkdir -p /var/log/cacti
  chown www-data:www-data /var/log/cacti
  success "Cron configurado"
}

# --- SNMPD -------------------------------------------------------------------
configure_snmpd() {
  step "Configurando SNMPd local"

  cat > /etc/snmp/snmpd.conf <<'SNMPCONF'
# Cacti local SNMP
rocommunity public  127.0.0.1
rocommunity public  localhost
syslocation  "Servidor Cacti"
syscontact   admin@localhost

# Para HMIB
view   systemview  included  .1.3.6.1.2.1
view   systemview  included  .1.3.6.1.4.1
extend .1.3.6.1.4.1.2021.7890.1 distro /usr/local/bin/distro
SNMPCONF

  systemctl enable snmpd --quiet
  systemctl restart snmpd
  success "SNMPd configurado"
}

# --- PLUGINS -----------------------------------------------------------------
install_plugin() {
  local PLUGIN="$1"
  local REPO="${PLUGIN_REPOS[$PLUGIN]}"
  local BRANCH="${PLUGIN_BRANCHES[$PLUGIN]:-develop}"
  local DEST="${CACTI_WEB_DIR}/plugins/${PLUGIN}"

  info "Plugin: ${PLUGIN} (branch: ${BRANCH})"

  if [[ -d "$DEST/.git" ]]; then
    # Atualizar se já existe
    git -C "$DEST" fetch --all -q
    git -C "$DEST" checkout "$BRANCH" -q 2>/dev/null || git -C "$DEST" checkout "main" -q 2>/dev/null || true
    git -C "$DEST" pull --ff-only -q
    success "Plugin ${PLUGIN} atualizado"
  else
    [[ -d "$DEST" ]] && rm -rf "$DEST"
    git clone --depth=1 --branch "$BRANCH" "$REPO" "$DEST" -q 2>/dev/null || \
      git clone --depth=1 "$REPO" "$DEST" -q || \
      { warn "Falha ao clonar ${PLUGIN} — pulando"; return 1; }
    success "Plugin ${PLUGIN} instalado"
  fi

  chown -R www-data:www-data "$DEST"
  chmod -R 755 "$DEST"
}

install_all_plugins() {
  step "Instalando plugins"

  mkdir -p "${CACTI_WEB_DIR}/plugins"

  local FAILED=()
  for PLUGIN in "${!PLUGIN_REPOS[@]}"; do
    install_plugin "$PLUGIN" || FAILED+=("$PLUGIN")
  done

  # Configurações específicas por plugin
  configure_plugin_syslog
  configure_plugin_weathermap
  configure_plugin_flowview
  configure_plugin_routerconfigs

  if [[ ${#FAILED[@]} -gt 0 ]]; then
    warn "Plugins com falha: ${FAILED[*]}"
    warn "Verifique conectividade e tente: $0 --update"
  fi

  success "Plugins instalados"
}

configure_plugin_syslog() {
  local CONF="${CACTI_WEB_DIR}/plugins/syslog/config.php"
  [[ -f "${CACTI_WEB_DIR}/plugins/syslog/config.php.dist" ]] || return
  cp "${CACTI_WEB_DIR}/plugins/syslog/config.php.dist" "$CONF" 2>/dev/null || true
  if [[ -f "$CONF" ]]; then
    sed -i "s/'cacti'/'${CACTI_DB_NAME}_syslog'/g" "$CONF" 2>/dev/null || true
    sed -i "s/'cactiuser'/'${CACTI_DB_USER}'/g" "$CONF" 2>/dev/null || true
    sed -i "s/'password'/'${CACTI_DB_PASS}'/g" "$CONF" 2>/dev/null || true
  fi

  # rsyslog para enviar ao syslog plugin (porta UDP 514)
  cat > /etc/rsyslog.d/cacti-syslog.conf <<'RSY'
# Encaminhar syslog para o plugin Syslog do Cacti
*.* @127.0.0.1:514
RSY
  systemctl restart rsyslog 2>/dev/null || true
}

configure_plugin_weathermap() {
  local WM_DIR="${CACTI_WEB_DIR}/plugins/weathermap"
  [[ -d "$WM_DIR" ]] || return
  mkdir -p "${WM_DIR}/configs" "${WM_DIR}/output" "${WM_DIR}/tmp"
  chown -R www-data:www-data "${WM_DIR}/configs" "${WM_DIR}/output" "${WM_DIR}/tmp"
  chmod -R 775 "${WM_DIR}/configs" "${WM_DIR}/output" "${WM_DIR}/tmp"
}

configure_plugin_flowview() {
  local FV_DIR="${CACTI_WEB_DIR}/plugins/flowview"
  [[ -d "$FV_DIR" ]] || return
  # Diretório para armazenar flows
  mkdir -p /var/lib/netflow/flows
  chown -R www-data:www-data /var/lib/netflow
  # fprobe capture (ajustar interface conforme necessário)
  if ! systemctl is-active fprobe &>/dev/null; then
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}' || echo "eth0")
    cat > /etc/default/fprobe <<FPROBE
INTERFACE="${IFACE}"
COLLECTOR="127.0.0.1:2055"
OPTIONS="-p udp -e 3600"
FPROBE
    systemctl enable fprobe 2>/dev/null || true
    systemctl start fprobe 2>/dev/null || true
  fi
}

configure_plugin_routerconfigs() {
  local RC_DIR="${CACTI_WEB_DIR}/plugins/routerconfigs"
  [[ -d "$RC_DIR" ]] || return
  mkdir -p /var/lib/cacti/routerconfigs
  chown -R www-data:www-data /var/lib/cacti/routerconfigs
  chmod 750 /var/lib/cacti/routerconfigs
}

# --- SEGURANÇA ---------------------------------------------------------------
configure_security() {
  step "Aplicando configurações de segurança"

  # PHP hardening
  for ini in /etc/php/*/apache2/php.ini; do
    [[ -f "$ini" ]] || continue
    sed -i 's/expose_php = On/expose_php = Off/' "$ini"
    sed -i 's/display_errors = On/display_errors = Off/' "$ini"
    sed -i 's/log_errors = Off/log_errors = On/' "$ini"
  done

  # UFW / firewall básico
  if command -v ufw &>/dev/null; then
    ufw allow 80/tcp comment "Cacti HTTP" 2>/dev/null || true
    ufw allow 443/tcp comment "Cacti HTTPS" 2>/dev/null || true
    ufw allow 161/udp comment "SNMP" 2>/dev/null || true
    ufw allow 514/udp comment "Syslog" 2>/dev/null || true
    ufw allow 2055/udp comment "NetFlow" 2>/dev/null || true
  fi

  success "Segurança configurada"
}

# --- ATUALIZAÇÃO -------------------------------------------------------------
do_update() {
  step "Modo ATUALIZAÇÃO"
  load_config

  info "Atualizando plugins via git..."
  for PLUGIN in "${!PLUGIN_REPOS[@]}"; do
    local DEST="${CACTI_WEB_DIR}/plugins/${PLUGIN}"
    if [[ -d "$DEST/.git" ]]; then
      git -C "$DEST" pull --ff-only -q && success "Plugin ${PLUGIN} atualizado" || warn "Falha ao atualizar ${PLUGIN}"
    else
      warn "Plugin ${PLUGIN} não encontrado — instale primeiro com: $0"
    fi
  done

  success "Atualização concluída. Reinicie o Apache: systemctl restart apache2"
  exit 0
}

do_update_plugin() {
  local PLUGIN="$1"
  load_config
  [[ -n "${PLUGIN_REPOS[$PLUGIN]+x}" ]] || error "Plugin desconhecido: $PLUGIN"
  step "Atualizando plugin: ${PLUGIN}"
  install_plugin "$PLUGIN"
  exit 0
}

# --- RESUMO FINAL ------------------------------------------------------------
print_summary() {
  step "Instalação concluída!"
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║           CACTI INSTALADO COM SUCESSO!           ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}URL de acesso:${NC}   http://$(hostname -I | awk '{print $1}')/cacti/"
  echo -e "  ${BOLD}Utilizador:${NC}      admin"
  echo -e "  ${BOLD}Password:${NC}        ${CACTI_ADMIN_PASS}"
  echo ""
  echo -e "  ${BOLD}BD Cacti:${NC}        ${CACTI_DB_NAME}"
  echo -e "  ${BOLD}User BD:${NC}         ${CACTI_DB_USER}"
  echo -e "  ${BOLD}Pass BD:${NC}         ${CACTI_DB_PASS}"
  echo ""
  echo -e "  ${BOLD}Config salvo em:${NC} ${CONFIG_FILE}"
  echo -e "  ${BOLD}Log completo:${NC}    ${LOG_FILE}"
  echo ""
  echo -e "  ${YELLOW}IMPORTANTE:${NC} Acesse a URL e complete o wizard de instalação."
  echo -e "  Após o wizard, ative os plugins em:"
  echo -e "  Console → Configuration → Plugin Management"
  echo ""
  echo -e "${CYAN}Comandos úteis:${NC}"
  echo -e "  Atualizar todos os plugins: ${BOLD}sudo bash $0 --update${NC}"
  echo -e "  Atualizar plugin específico: ${BOLD}sudo bash $0 --plugin thold${NC}"
  echo ""
}

# --- MAIN --------------------------------------------------------------------
main() {
  # Parse argumentos
  MODE="install"
  PLUGIN_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update)       MODE="update" ;;
      --plugin)       MODE="update-plugin"; PLUGIN_NAME="${2:-}"; shift ;;
      --db-pass)      CACTI_DB_PASS="${2:-}"; shift ;;
      --admin-pass)   CACTI_ADMIN_PASS="${2:-}"; shift ;;
      --help|-h)
        echo "Uso: sudo bash $0 [opções]"
        echo "  --update            Atualiza todos os plugins"
        echo "  --plugin <nome>     Atualiza plugin específico"
        echo "  --db-pass <senha>   Define senha do banco"
        echo "  --admin-pass <s>    Define senha do admin Cacti"
        exit 0
        ;;
      *) warn "Argumento desconhecido: $1" ;;
    esac
    shift
  done

  exec > >(tee -a "$LOG_FILE") 2>&1
  check_root

  case "$MODE" in
    update)        do_update ;;
    update-plugin) do_update_plugin "$PLUGIN_NAME" ;;
    install)
      load_config
      detect_os
      check_proxmox_vm
      install_dependencies
      configure_mariadb
      install_cacti
      install_spine
      configure_apache
      configure_cron
      configure_snmpd
      install_all_plugins
      configure_security
      save_config
      print_summary
      ;;
  esac
}

main "$@"
