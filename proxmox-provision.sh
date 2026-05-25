#!/usr/bin/env bash
# =============================================================================
# Cacti - Provisionamento de VM no Proxmox VE
# Cria VM, instala OS e executa cacti-install.sh automaticamente
# Executar no HOST Proxmox como root
#
# Uso: bash proxmox-provision.sh
#      (configuração em cacti-deploy.conf no mesmo diretório)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cacti-deploy.conf"

# --- CARREGAR CONFIGURAÇÃO ---------------------------------------------------
[[ -f "$CONF_FILE" ]] || {
  echo "[ERRO] Ficheiro de configuração não encontrado: $CONF_FILE"
  echo "       Cria o ficheiro cacti-deploy.conf no mesmo diretório do script."
  exit 1
}
source "$CONF_FILE"

# Valores padrão para variáveis opcionais
VMID="${VMID:-200}"
VM_NAME="${VM_NAME:-cacti-monitoring}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_VLAN="${VM_VLAN:-}"
VM_IP="${VM_IP:-dhcp}"
VM_GW="${VM_GW:-}"
VM_DNS="${VM_DNS:-8.8.8.8}"
VM_SSHKEY="${VM_SSHKEY:-}"
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
CLOUD_IMAGE_FILE="/var/lib/vz/template/qemu/debian-12-genericcloud-amd64.qcow2"
CLOUD_USER="${CLOUD_USER:-root}"
CLOUD_PASS="${CLOUD_PASS:-$(openssl rand -base64 12)}"
CACTI_DB_PASS="${CACTI_DB_PASS:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c20)}"
CACTI_ADMIN_PASS="${CACTI_ADMIN_PASS:-admin}"
CACTI_SCRIPT_DIR="/opt/cacti-deploy"

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "$(date '+%H:%M:%S') $*"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
success() { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══  $*  ══${NC}"; }

# --- VERIFICAÇÕES ------------------------------------------------------------
check_proxmox_host() {
  command -v pvesh &>/dev/null || error "Este script deve ser executado no host Proxmox VE"
  [[ $EUID -eq 0 ]] || error "Execute como root no host Proxmox"
}

check_vmid() {
  if pvesh get /nodes/$(hostname)/qemu/${VMID}/status/current &>/dev/null 2>&1; then
    error "VMID ${VMID} já existe. Altera o VMID no cacti-deploy.conf."
  fi
  success "VMID ${VMID} disponível"
}

validate_config() {
  step "Validando configuração"

  # Alertar senhas padrão
  local WARN_PASS=0
  [[ "$CLOUD_PASS"       == "alterar-esta-senha" ]] && { warn "CLOUD_PASS não foi alterada no cacti-deploy.conf!"; WARN_PASS=1; }
  [[ "$CACTI_DB_PASS"    == "alterar-esta-senha" ]] && { warn "CACTI_DB_PASS não foi alterada no cacti-deploy.conf!"; WARN_PASS=1; }
  [[ "$CACTI_ADMIN_PASS" == "alterar-esta-senha" ]] && { warn "CACTI_ADMIN_PASS não foi alterada no cacti-deploy.conf!"; WARN_PASS=1; }

  if [[ $WARN_PASS -eq 1 ]]; then
    echo ""
    echo -e "${YELLOW}Tens senhas padrão no cacti-deploy.conf. Continuar mesmo assim? (s/N)${NC}"
    read -r CONFIRM
    [[ "${CONFIRM,,}" == "s" ]] || { echo "Edita o cacti-deploy.conf e tenta novamente."; exit 0; }
  fi

  [[ "$VM_IP" != "dhcp" && -z "$VM_GW" ]] && error "VM_GW é obrigatório quando VM_IP é estático."
  success "Configuração validada"
}

# --- CLOUD IMAGE -------------------------------------------------------------
download_cloud_image() {
  step "Imagem Cloud"
  if [[ -f "$CLOUD_IMAGE_FILE" ]]; then
    info "Imagem já existe: $CLOUD_IMAGE_FILE"
    return
  fi
  mkdir -p "$(dirname "$CLOUD_IMAGE_FILE")"
  info "Download: $CLOUD_IMAGE_URL"
  wget -q --show-progress -O "$CLOUD_IMAGE_FILE" "$CLOUD_IMAGE_URL"
  success "Imagem baixada"
}

# --- CRIAR VM ----------------------------------------------------------------
create_vm() {
  step "Criando VM ${VMID}: ${VM_NAME}"

  qm create "${VMID}" \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY}" \
    --cores "${VM_CORES}" \
    --cpu host \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${VM_STORAGE}:4,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --boot order=scsi0 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --onboot 1 \
    --tags "cacti,monitoring"

  info "Importando imagem de disco..."
  qm importdisk "${VMID}" "${CLOUD_IMAGE_FILE}" "${VM_STORAGE}" --format qcow2
  qm set "${VMID}" --scsi0 "${VM_STORAGE}:vm-${VMID}-disk-1,discard=on,ssd=1,iothread=1"
  qm resize "${VMID}" scsi0 "${VM_DISK_SIZE}G"

  qm set "${VMID}" --ide2 "${VM_STORAGE}:cloudinit"

  local NET_OPTS="virtio,bridge=${VM_BRIDGE}"
  [[ -n "${VM_VLAN}" ]] && NET_OPTS="${NET_OPTS},tag=${VM_VLAN}"
  qm set "${VMID}" --net0 "${NET_OPTS}"

  qm set "${VMID}" \
    --ciuser "${CLOUD_USER}" \
    --cipassword "${CLOUD_PASS}" \
    --nameserver "${VM_DNS}" \
    --searchdomain "local"

  if [[ "$VM_IP" == "dhcp" ]]; then
    qm set "${VMID}" --ipconfig0 "ip=dhcp"
  else
    qm set "${VMID}" --ipconfig0 "ip=${VM_IP},gw=${VM_GW}"
  fi

  if [[ -n "$VM_SSHKEY" && -f "$VM_SSHKEY" ]]; then
    qm set "${VMID}" --sshkeys "${VM_SSHKEY}"
    success "Chave SSH configurada"
  fi

  # Cloud-init user-data para instalar Cacti automaticamente
  local USERDATA_FILE="/var/lib/vz/snippets/cacti-${VMID}-userdata.yaml"
  mkdir -p /var/lib/vz/snippets

  cat > "${USERDATA_FILE}" <<YAML
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
package_update: true
package_upgrade: true
packages:
  - git
  - curl
  - wget
runcmd:
  - mkdir -p ${CACTI_SCRIPT_DIR}
  - git clone https://github.com/rcsmota/cacti-proxymox-deploy.git ${CACTI_SCRIPT_DIR}
  - cp ${CACTI_SCRIPT_DIR}/cacti-deploy.conf.example ${CACTI_SCRIPT_DIR}/cacti-deploy.conf
  - chmod +x ${CACTI_SCRIPT_DIR}/cacti-install.sh
  - |
    export CACTI_DB_PASS="${CACTI_DB_PASS}"
    export CACTI_ADMIN_PASS="${CACTI_ADMIN_PASS}"
    bash ${CACTI_SCRIPT_DIR}/cacti-install.sh 2>&1 | tee /var/log/cacti-install.log
final_message: "Cacti instalado!"
YAML

  qm set "${VMID}" --cicustom "user=local:snippets/cacti-${VMID}-userdata.yaml"

  success "VM ${VMID} criada"
}

# --- INICIAR VM --------------------------------------------------------------
start_vm() {
  step "Iniciando VM"
  qm start "${VMID}"
  success "VM ${VMID} iniciada"

  info "Aguardando boot (90s)..."
  sleep 90
}

# --- INSTALAR VIA SSH --------------------------------------------------------
install_via_ssh() {
  step "Transferindo scripts e instalando Cacti na VM"

  local TARGET_IP
  if [[ "$VM_IP" == "dhcp" ]]; then
    warn "IP DHCP — aguardando QEMU agent (30s)..."
    sleep 30
    TARGET_IP=$(qm guest exec "${VMID}" -- hostname -I 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | grep -v 127 | head -1 || echo "")
  else
    TARGET_IP="${VM_IP%%/*}"
  fi

  if [[ -z "$TARGET_IP" ]]; then
    warn "Não foi possível determinar o IP automaticamente."
    warn "Instala manualmente: ssh ${CLOUD_USER}@<IP-VM> 'bash ${CACTI_SCRIPT_DIR}/cacti-install.sh'"
    return
  fi

  info "IP da VM: ${TARGET_IP}"

  local RETRIES=12
  while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
              "${CLOUD_USER}@${TARGET_IP}" "echo ok" &>/dev/null; do
    [[ $RETRIES -le 0 ]] && { warn "SSH não disponível. Instala manualmente."; return; }
    info "Aguardando SSH... ($RETRIES tentativas)"
    sleep 10
    ((RETRIES--))
  done

  info "Transferindo scripts..."
  ssh -o StrictHostKeyChecking=no "${CLOUD_USER}@${TARGET_IP}" "mkdir -p ${CACTI_SCRIPT_DIR}"
  scp -o StrictHostKeyChecking=no -r "${SCRIPT_DIR}/"* "${CLOUD_USER}@${TARGET_IP}:${CACTI_SCRIPT_DIR}/"

  info "Iniciando instalação do Cacti..."
  ssh -o StrictHostKeyChecking=no "${CLOUD_USER}@${TARGET_IP}" \
    "export CACTI_DB_PASS='${CACTI_DB_PASS}'; export CACTI_ADMIN_PASS='${CACTI_ADMIN_PASS}'; bash ${CACTI_SCRIPT_DIR}/cacti-install.sh 2>&1 | tee /var/log/cacti-install.log"

  success "Cacti instalado via SSH"
  echo ""
  echo -e "${GREEN}${BOLD}Acesse: http://${TARGET_IP}/cacti/${NC}"
}

# --- RESUMO ------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║        VM PROXMOX CRIADA COM SUCESSO!        ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}VMID:${NC}            ${VMID}"
  echo -e "  ${BOLD}Nome:${NC}            ${VM_NAME}"
  echo -e "  ${BOLD}RAM:${NC}             ${VM_MEMORY} MB"
  echo -e "  ${BOLD}CPU:${NC}             ${VM_CORES} cores"
  echo -e "  ${BOLD}Disco:${NC}           ${VM_DISK_SIZE} GB"
  echo -e "  ${BOLD}Storage:${NC}         ${VM_STORAGE}"
  echo -e "  ${BOLD}Rede:${NC}            ${VM_BRIDGE}${VM_VLAN:+ VLAN ${VM_VLAN}}"
  echo -e "  ${BOLD}IP:${NC}              ${VM_IP}"
  echo -e "  ${BOLD}User VM:${NC}         ${CLOUD_USER}"
  echo -e "  ${BOLD}Senha VM:${NC}        ${CLOUD_PASS}"
  echo -e "  ${BOLD}URL Cacti:${NC}       http://${VM_IP%%/*}/cacti/"
  echo -e "  ${BOLD}Admin Cacti:${NC}     admin / ${CACTI_ADMIN_PASS}"
  echo -e "  ${BOLD}BD:${NC}              ${CACTI_DB_NAME} / ${CACTI_DB_USER} / ${CACTI_DB_PASS}"
  echo ""
  echo -e "  ${YELLOW}Acompanha a instalação:${NC}"
  echo -e "  ssh ${CLOUD_USER}@${VM_IP%%/*} 'tail -f /var/log/cacti-install.log'"
  echo ""
}

# --- MAIN --------------------------------------------------------------------
main() {
  check_proxmox_host
  validate_config
  check_vmid
  download_cloud_image
  create_vm
  start_vm
  install_via_ssh
  print_summary
}

main "$@"
