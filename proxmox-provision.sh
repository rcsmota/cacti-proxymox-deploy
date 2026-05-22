#!/usr/bin/env bash
# =============================================================================
# Cacti - Provisionamento de VM no Proxmox VE
# Cria VM, instala OS e executa cacti-install.sh automaticamente
# Executar no HOST Proxmox como root
# Uso: bash proxmox-provision.sh [--vmid 200] [--name cacti-01]
# =============================================================================

set -euo pipefail

# --- CONFIGURAÇÃO DA VM ------------------------------------------------------
VMID="${VMID:-200}"
VM_NAME="${VM_NAME:-cacti-monitoring}"
VM_MEMORY="${VM_MEMORY:-4096}"          # MB
VM_CORES="${VM_CORES:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40}"      # GB
VM_STORAGE="${VM_STORAGE:-local-lvm}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_VLAN="${VM_VLAN:-}"                  # Deixar vazio para sem VLAN tag
VM_IP="${VM_IP:-dhcp}"                  # Ex: 10.25.148.50/22
VM_GW="${VM_GW:-}"                      # Gateway (se IP estático)
VM_DNS="${VM_DNS:-8.8.8.8}"
VM_SSHKEY="${VM_SSHKEY:-}"              # Path para chave SSH pública

# Cloud-init / OS
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
CLOUD_IMAGE_FILE="/var/lib/vz/template/qemu/debian-12-genericcloud-amd64.qcow2"
CLOUD_USER="${CLOUD_USER:-cacti}"
CLOUD_PASS="${CLOUD_PASS:-$(openssl rand -base64 12)}"

# Script remoto
CACTI_SCRIPT_DIR="/opt/cacti-deploy"
CACTI_INSTALL_REMOTE_PATH="${CACTI_SCRIPT_DIR}/cacti-install.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "$(date '+%H:%M:%S') $*"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
success() { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══  $*  ══${NC}"; }

# --- PARSE ARGS --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)     VMID="$2"; shift ;;
    --name)     VM_NAME="$2"; shift ;;
    --memory)   VM_MEMORY="$2"; shift ;;
    --cores)    VM_CORES="$2"; shift ;;
    --disk)     VM_DISK_SIZE="$2"; shift ;;
    --storage)  VM_STORAGE="$2"; shift ;;
    --bridge)   VM_BRIDGE="$2"; shift ;;
    --vlan)     VM_VLAN="$2"; shift ;;
    --ip)       VM_IP="$2"; shift ;;
    --gw)       VM_GW="$2"; shift ;;
    --sshkey)   VM_SSHKEY="$2"; shift ;;
    --help|-h)
      echo "Uso: bash proxmox-provision.sh [opções]"
      echo "  --vmid <id>       ID da VM (padrão: 200)"
      echo "  --name <nome>     Nome da VM (padrão: cacti-monitoring)"
      echo "  --memory <MB>     RAM em MB (padrão: 4096)"
      echo "  --cores <n>       Número de cores (padrão: 4)"
      echo "  --disk <GB>       Tamanho do disco (padrão: 40)"
      echo "  --storage <s>     Storage Proxmox (padrão: local-lvm)"
      echo "  --bridge <b>      Bridge de rede (padrão: vmbr0)"
      echo "  --vlan <id>       VLAN tag (opcional)"
      echo "  --ip <cidr>       IP estático (ex: 10.25.148.50/22) ou 'dhcp'"
      echo "  --gw <ip>         Gateway (necessário se IP estático)"
      echo "  --sshkey <path>   Chave SSH pública para acesso"
      exit 0
      ;;
    *) warn "Argumento desconhecido: $1" ;;
  esac
  shift
done

# --- VERIFICAÇÕES ------------------------------------------------------------
check_proxmox_host() {
  command -v pvesh &>/dev/null || error "Este script deve ser executado no host Proxmox VE"
  [[ $EUID -eq 0 ]] || error "Execute como root no host Proxmox"
}

check_vmid() {
  if pvesh get /nodes/$(hostname)/qemu/${VMID}/status/current &>/dev/null 2>&1; then
    error "VMID ${VMID} já existe. Use --vmid para escolher outro."
  fi
  success "VMID ${VMID} disponível"
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

  # Criar VM base
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

  # Disco principal (importar cloud image)
  info "Importando imagem de disco..."
  qm importdisk "${VMID}" "${CLOUD_IMAGE_FILE}" "${VM_STORAGE}" --format qcow2
  qm set "${VMID}" --scsi0 "${VM_STORAGE}:vm-${VMID}-disk-1,discard=on,ssd=1,iothread=1"
  qm resize "${VMID}" scsi0 "${VM_DISK_SIZE}G"

  # Drive cloud-init
  qm set "${VMID}" --ide2 "${VM_STORAGE}:cloudinit"

  # Rede
  local NET_OPTS="virtio,bridge=${VM_BRIDGE}"
  [[ -n "${VM_VLAN}" ]] && NET_OPTS="${NET_OPTS},tag=${VM_VLAN}"
  qm set "${VMID}" --net0 "${NET_OPTS}"

  # Cloud-init básico
  qm set "${VMID}" \
    --ciuser "${CLOUD_USER}" \
    --cipassword "${CLOUD_PASS}" \
    --nameserver "${VM_DNS}" \
    --searchdomain "local"

  # IP
  if [[ "$VM_IP" == "dhcp" ]]; then
    qm set "${VMID}" --ipconfig0 "ip=dhcp"
  else
    [[ -z "$VM_GW" ]] && error "Gateway (--gw) obrigatório para IP estático"
    qm set "${VMID}" --ipconfig0 "ip=${VM_IP},gw=${VM_GW}"
  fi

  # Chave SSH
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
  - cd ${CACTI_SCRIPT_DIR}
  # Copiar scripts (via volume ou download)
  - |
    if [ -d /mnt/cacti-deploy ]; then
      cp -r /mnt/cacti-deploy/* ${CACTI_SCRIPT_DIR}/
    fi
  - chmod +x ${CACTI_INSTALL_REMOTE_PATH}
  - bash ${CACTI_INSTALL_REMOTE_PATH} 2>&1 | tee /var/log/cacti-install.log

final_message: "Cacti instalado! Acesse http://\$_INSTANCE_IP/cacti/"
YAML

  qm set "${VMID}" \
    --cicustom "user=local:snippets/cacti-${VMID}-userdata.yaml"

  success "VM ${VMID} criada"
}

# --- TRANSFERIR SCRIPTS ------------------------------------------------------
transfer_scripts() {
  step "Preparando scripts para transferência"

  # Copiar scripts para snippets do Proxmox (serão copiados via cloud-init ou SSH)
  local SNIPPETS_DIR="/var/lib/vz/snippets/cacti-deploy-${VMID}"
  mkdir -p "${SNIPPETS_DIR}"
  cp -r "${SCRIPT_DIR}/"* "${SNIPPETS_DIR}/" 2>/dev/null || true

  info "Scripts disponíveis em: ${SNIPPETS_DIR}"
  info "Após boot da VM, transfira com:"
  info "  scp -r ${SCRIPT_DIR}/ ${CLOUD_USER}@<IP-VM>:${CACTI_SCRIPT_DIR}/"
}

# --- INICIAR VM --------------------------------------------------------------
start_vm() {
  step "Iniciando VM"
  qm start "${VMID}"
  success "VM ${VMID} iniciada"

  info "Aguardando boot (90s)..."
  sleep 90

  # Tentar obter IP se DHCP
  if [[ "$VM_IP" == "dhcp" ]]; then
    local VM_IP_ACTUAL
    VM_IP_ACTUAL=$(qm guest exec "${VMID}" -- ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1 2>/dev/null || echo "Obter via: qm guest exec ${VMID} -- hostname -I")
    info "IP da VM: ${VM_IP_ACTUAL}"
  fi
}

# --- INSTALAR VIA SSH --------------------------------------------------------
install_via_ssh() {
  step "Instalando Cacti na VM via SSH"

  local TARGET_IP
  if [[ "$VM_IP" == "dhcp" ]]; then
    warn "IP DHCP — aguardando mais 30s para QEMU agent reportar IP..."
    sleep 30
    TARGET_IP=$(qm guest exec "${VMID}" -- hostname -I 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | grep -v 127 | head -1 || echo "")
  else
    TARGET_IP="${VM_IP%%/*}"  # Remover prefixo CIDR
  fi

  if [[ -z "$TARGET_IP" ]]; then
    warn "Não foi possível determinar o IP da VM automaticamente."
    warn "Para instalar manualmente, execute na VM:"
    warn "  sudo bash ${CACTI_INSTALL_REMOTE_PATH}"
    return
  fi

  info "IP da VM: ${TARGET_IP}"
  info "Transferindo scripts..."

  # Aguardar SSH disponível
  local RETRIES=12
  while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
              "${CLOUD_USER}@${TARGET_IP}" "echo ok" &>/dev/null; do
    [[ $RETRIES -le 0 ]] && { warn "SSH não disponível. Instale manualmente."; return; }
    info "Aguardando SSH... ($RETRIES tentativas restantes)"
    sleep 10
    ((RETRIES--))
  done

  ssh -o StrictHostKeyChecking=no "${CLOUD_USER}@${TARGET_IP}" "sudo mkdir -p ${CACTI_SCRIPT_DIR}"
  scp -o StrictHostKeyChecking=no -r "${SCRIPT_DIR}/"* "${CLOUD_USER}@${TARGET_IP}:${CACTI_SCRIPT_DIR}/"
  ssh -o StrictHostKeyChecking=no "${CLOUD_USER}@${TARGET_IP}" \
    "sudo bash ${CACTI_INSTALL_REMOTE_PATH} 2>&1 | tee /var/log/cacti-install.log"

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
  echo -e "  ${BOLD}VMID:${NC}          ${VMID}"
  echo -e "  ${BOLD}Nome:${NC}          ${VM_NAME}"
  echo -e "  ${BOLD}RAM:${NC}           ${VM_MEMORY} MB"
  echo -e "  ${BOLD}CPU:${NC}           ${VM_CORES} cores"
  echo -e "  ${BOLD}Disco:${NC}         ${VM_DISK_SIZE} GB"
  echo -e "  ${BOLD}Storage:${NC}       ${VM_STORAGE}"
  echo -e "  ${BOLD}Rede:${NC}          ${VM_BRIDGE}${VM_VLAN:+ VLAN ${VM_VLAN}}"
  echo -e "  ${BOLD}IP:${NC}            ${VM_IP}"
  echo -e "  ${BOLD}User Cloud:${NC}    ${CLOUD_USER}"
  echo -e "  ${BOLD}Pass Cloud:${NC}    ${CLOUD_PASS}"
  echo ""
  echo -e "  ${YELLOW}Aguarde ~5min para instalação completa do Cacti na VM.${NC}"
  echo -e "  ${YELLOW}Acompanhe: ssh ${CLOUD_USER}@<IP-VM> 'tail -f /var/log/cacti-install.log'${NC}"
  echo ""
}

# --- MAIN --------------------------------------------------------------------
main() {
  check_proxmox_host
  check_vmid
  download_cloud_image
  create_vm
  transfer_scripts
  start_vm
  install_via_ssh
  print_summary
}

main "$@"
