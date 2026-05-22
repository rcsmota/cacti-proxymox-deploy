#!/usr/bin/env bash
# =============================================================================
# cacti-plugin-manager.sh
# Gestão interativa de plugins Cacti: instalar, atualizar, remover, status
# Uso: sudo bash cacti-plugin-manager.sh
# =============================================================================

set -euo pipefail

CACTI_WEB_DIR="/var/www/html/cacti"
PLUGINS_DIR="${CACTI_WEB_DIR}/plugins"
LOG_FILE="/var/log/cacti-plugins.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
NC='\033[0m'; BOLD='\033[1m'

# Mapeamento completo de plugins
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

declare -A PLUGIN_DESC=(
  [thold]="Fault Management - Alertas e limiares de threshold"
  [syslog]="Log Management - Coleta e análise de Syslog"
  [maint]="Maintenance Management - Janelas de manutenção"
  [monitor]="Host Status Dashboard - Painel de disponibilidade"
  [hmib]="SNMP Host MIB - Monitoramento de atributos MIB"
  [webseer]="Web Service Checks - Verificação de serviços HTTP/S"
  [gexport]="Graph Exports - Exportação automática de gráficos"
  [intropage]="Console Dashboard - Substituição do console Cacti"
  [audit]="Change Audit - Rastreamento de alterações"
  [routerconfigs]="Router Configs - Backup de configurações de dispositivos"
  [weathermap]="Weathermap - Mapa de tráfego de rede"
  [flowview]="FlowView - Graphing de NetFlow/sFlow"
)

log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# --- STATUS ------------------------------------------------------------------
plugin_status() {
  local PLUGIN="$1"
  local DIR="${PLUGINS_DIR}/${PLUGIN}"

  if [[ ! -d "$DIR" ]]; then
    echo "NAO_INSTALADO"
    return
  fi

  if [[ -d "$DIR/.git" ]]; then
    local CURRENT_COMMIT REMOTE_COMMIT BRANCH
    BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null || echo "detached")
    CURRENT_COMMIT=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo "?")
    # Checar se há atualizações disponíveis
    git -C "$DIR" fetch --quiet 2>/dev/null || true
    REMOTE_COMMIT=$(git -C "$DIR" rev-parse --short "@{u}" 2>/dev/null || echo "?")

    if [[ "$CURRENT_COMMIT" == "$REMOTE_COMMIT" || "$REMOTE_COMMIT" == "?" ]]; then
      echo "ATUALIZADO:${BRANCH}:${CURRENT_COMMIT}"
    else
      echo "DESATUALIZADO:${BRANCH}:${CURRENT_COMMIT}:${REMOTE_COMMIT}"
    fi
  else
    echo "INSTALADO_SEM_GIT"
  fi
}

# --- MOSTRAR TABELA ----------------------------------------------------------
show_status_table() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║                    STATUS DOS PLUGINS CACTI                         ║${NC}"
  echo -e "${BOLD}${CYAN}╠══════════════════════╦══════════════════╦═══════════════════════════╣${NC}"
  printf "${BOLD}${CYAN}║${NC} %-20s ${BOLD}${CYAN}║${NC} %-16s ${BOLD}${CYAN}║${NC} %-25s ${BOLD}${CYAN}║${NC}\n" "PLUGIN" "STATUS" "BRANCH/COMMIT"
  echo -e "${BOLD}${CYAN}╠══════════════════════╬══════════════════╬═══════════════════════════╣${NC}"

  for PLUGIN in "${!PLUGIN_REPOS[@]}"; do
    local STATUS_RAW
    STATUS_RAW=$(plugin_status "$PLUGIN")
    local STATUS_LABEL EXTRA COLOR

    IFS=':' read -r STATUS_TYPE BRANCH COMMIT REMOTE_COMMIT <<< "${STATUS_RAW}::::"

    case "$STATUS_TYPE" in
      ATUALIZADO)
        STATUS_LABEL="✓ Atualizado"
        EXTRA="${BRANCH}@${COMMIT}"
        COLOR="${GREEN}"
        ;;
      DESATUALIZADO)
        STATUS_LABEL="↑ Atualizar"
        EXTRA="${BRANCH}@${COMMIT}"
        COLOR="${YELLOW}"
        ;;
      INSTALADO_SEM_GIT)
        STATUS_LABEL="? Sem git"
        EXTRA="-"
        COLOR="${YELLOW}"
        ;;
      NAO_INSTALADO)
        STATUS_LABEL="✗ Não instalado"
        EXTRA="-"
        COLOR="${RED}"
        ;;
      *)
        STATUS_LABEL="? Desconhecido"
        EXTRA="-"
        COLOR="${MAGENTA}"
        ;;
    esac

    printf "${BOLD}${CYAN}║${NC} ${BOLD}%-20s${NC} ${BOLD}${CYAN}║${NC} ${COLOR}%-16s${NC} ${BOLD}${CYAN}║${NC} %-25s ${BOLD}${CYAN}║${NC}\n" \
      "$PLUGIN" "$STATUS_LABEL" "$EXTRA"
  done

  echo -e "${BOLD}${CYAN}╚══════════════════════╩══════════════════╩═══════════════════════════╝${NC}"
  echo ""
}

# --- INSTALAR UM PLUGIN ------------------------------------------------------
install_plugin() {
  local PLUGIN="$1"
  local BRANCH="${2:-develop}"
  local REPO="${PLUGIN_REPOS[$PLUGIN]}"
  local DEST="${PLUGINS_DIR}/${PLUGIN}"

  echo -e "\n${BLUE}[INFO]${NC} Instalando ${BOLD}${PLUGIN}${NC}..."
  log "Instalando plugin: $PLUGIN"

  [[ -d "$DEST/.git" ]] && { update_plugin "$PLUGIN"; return; }
  [[ -d "$DEST" ]] && rm -rf "$DEST"

  git clone --depth=1 --branch "$BRANCH" "$REPO" "$DEST" 2>/dev/null || \
  git clone --depth=1 "$REPO" "$DEST" || { echo -e "${RED}[ERRO]${NC} Falha ao clonar ${PLUGIN}"; return 1; }

  chown -R www-data:www-data "$DEST"
  chmod -R 755 "$DEST"
  echo -e "${GREEN}[OK]${NC}   Plugin ${BOLD}${PLUGIN}${NC} instalado"
  log "Plugin instalado: $PLUGIN"
}

# --- ATUALIZAR UM PLUGIN -----------------------------------------------------
update_plugin() {
  local PLUGIN="$1"
  local DEST="${PLUGINS_DIR}/${PLUGIN}"

  [[ ! -d "$DEST/.git" ]] && { install_plugin "$PLUGIN"; return; }

  echo -e "\n${BLUE}[INFO]${NC} Atualizando ${BOLD}${PLUGIN}${NC}..."
  log "Atualizando plugin: $PLUGIN"

  git -C "$DEST" fetch --all -q
  local BRANCH
  BRANCH=$(git -C "$DEST" branch --show-current 2>/dev/null || echo "develop")
  git -C "$DEST" pull --ff-only origin "$BRANCH" -q && \
    echo -e "${GREEN}[OK]${NC}   Plugin ${BOLD}${PLUGIN}${NC} atualizado" || \
    echo -e "${YELLOW}[WARN]${NC} Atualização com conflitos em ${PLUGIN}"

  chown -R www-data:www-data "$DEST"
  log "Plugin atualizado: $PLUGIN"
}

# --- ATUALIZAR TODOS ---------------------------------------------------------
update_all() {
  echo -e "\n${BOLD}${CYAN}Atualizando todos os plugins...${NC}\n"
  log "Atualização em massa iniciada"
  for PLUGIN in "${!PLUGIN_REPOS[@]}"; do
    local STATUS_RAW
    STATUS_RAW=$(plugin_status "$PLUGIN")
    if [[ "$STATUS_RAW" != "NAO_INSTALADO" ]]; then
      update_plugin "$PLUGIN"
    fi
  done
  echo ""
  echo -e "${GREEN}${BOLD}Atualização concluída!${NC}"
  echo -e "${YELLOW}Reinicie o Apache: systemctl restart apache2${NC}"
}

# --- REMOVER PLUGIN ----------------------------------------------------------
remove_plugin() {
  local PLUGIN="$1"
  local DEST="${PLUGINS_DIR}/${PLUGIN}"

  echo -e "\n${YELLOW}[WARN]${NC} Tem a certeza que deseja remover ${BOLD}${PLUGIN}${NC}? (s/N)"
  read -r CONFIRM
  [[ "${CONFIRM,,}" != "s" ]] && { echo "Cancelado."; return; }

  if [[ -d "$DEST" ]]; then
    # Criar backup
    local BACKUP="/tmp/cacti-plugin-backup-${PLUGIN}-$(date +%Y%m%d%H%M%S).tar.gz"
    tar -czf "$BACKUP" -C "${PLUGINS_DIR}" "$PLUGIN" 2>/dev/null
    rm -rf "$DEST"
    echo -e "${GREEN}[OK]${NC}   Plugin ${PLUGIN} removido (backup: ${BACKUP})"
    log "Plugin removido: $PLUGIN (backup: $BACKUP)"
  else
    echo -e "${YELLOW}[WARN]${NC} Plugin ${PLUGIN} não está instalado"
  fi
}

# --- MENU INTERATIVO ---------------------------------------------------------
show_menu() {
  while true; do
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║    CACTI PLUGIN MANAGER               ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo -e "  ${BOLD}1)${NC} Ver status de todos os plugins"
    echo -e "  ${BOLD}2)${NC} Atualizar todos os plugins"
    echo -e "  ${BOLD}3)${NC} Instalar plugin específico"
    echo -e "  ${BOLD}4)${NC} Atualizar plugin específico"
    echo -e "  ${BOLD}5)${NC} Remover plugin"
    echo -e "  ${BOLD}6)${NC} Reiniciar Apache"
    echo -e "  ${BOLD}0)${NC} Sair"
    echo ""
    echo -n "Escolha: "
    read -r OPT

    case "$OPT" in
      1) show_status_table ;;
      2) update_all ;;
      3)
        echo -e "\nPlugins disponíveis:"
        for P in "${!PLUGIN_REPOS[@]}"; do
          echo -e "  ${BOLD}${P}${NC} - ${PLUGIN_DESC[$P]}"
        done
        echo -n "Nome do plugin: "
        read -r P_NAME
        [[ -n "${PLUGIN_REPOS[$P_NAME]+x}" ]] && install_plugin "$P_NAME" || echo "Plugin desconhecido"
        ;;
      4)
        echo -e "\nPlugins instalados:"
        for P in "${!PLUGIN_REPOS[@]}"; do
          [[ -d "${PLUGINS_DIR}/${P}" ]] && echo "  ${P}"
        done
        echo -n "Nome do plugin: "
        read -r P_NAME
        [[ -n "${PLUGIN_REPOS[$P_NAME]+x}" ]] && update_plugin "$P_NAME" || echo "Plugin desconhecido"
        ;;
      5)
        echo -n "Nome do plugin para remover: "
        read -r P_NAME
        [[ -n "${PLUGIN_REPOS[$P_NAME]+x}" ]] && remove_plugin "$P_NAME" || echo "Plugin desconhecido"
        ;;
      6)
        systemctl restart apache2 && echo -e "${GREEN}[OK]${NC} Apache reiniciado"
        ;;
      0) echo "Saindo..."; exit 0 ;;
      *) echo -e "${YELLOW}Opção inválida${NC}" ;;
    esac
  done
}

# --- MAIN --------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Execute como root: sudo bash $0"; exit 1; }

# Modo não-interativo
case "${1:-menu}" in
  --status)   show_status_table ;;
  --update)   update_all ;;
  --install)  [[ -n "${2:-}" ]] && install_plugin "$2" || echo "Uso: $0 --install <plugin>" ;;
  --remove)   [[ -n "${2:-}" ]] && remove_plugin  "$2" || echo "Uso: $0 --remove <plugin>" ;;
  menu|*)     show_menu ;;
esac
