# Cacti 1.2.30 + Spine — Deploy Automatizado para Proxmox

Conjunto de scripts para instalação e gestão automatizada do Cacti com todos os plugins, em VMs Proxmox.

---

## Estrutura dos ficheiros

```
cacti-deploy/
├── cacti-install.sh          # Instalador principal (executar na VM)
├── proxmox-provision.sh      # Cria e provisiona a VM no host Proxmox
├── cacti-plugin-manager.sh   # Gestor interativo de plugins
└── README.md                 # Este ficheiro
```

---

## Cenários de uso

### Cenário 1 — VM já existente (instalar apenas o Cacti)

```bash
# Na VM (Debian 11/12 ou Ubuntu 20.04/22.04/24.04), como root:
git clone <repo> /opt/cacti-deploy
cd /opt/cacti-deploy
sudo bash cacti-install.sh
```

Variáveis de ambiente opcionais:
```bash
export CACTI_DB_PASS="minha-senha-bd"
export CACTI_ADMIN_PASS="minha-senha-admin"
sudo bash cacti-install.sh
```

---

### Cenário 2 — Criar VM nova no Proxmox + instalar Cacti

```bash
# No HOST Proxmox, como root:
cd /opt/cacti-deploy

# IP estático
sudo bash proxmox-provision.sh \
  --vmid 200 \
  --name cacti-monitoring \
  --memory 4096 \
  --cores 4 \
  --disk 40 \
  --storage local-lvm \
  --bridge vmbr0 \
  --vlan 148 \
  --ip 10.25.148.50/22 \
  --gw 10.25.148.1 \
  --sshkey ~/.ssh/id_rsa.pub

# DHCP (mais simples)
sudo bash proxmox-provision.sh \
  --vmid 201 \
  --name cacti-02 \
  --ip dhcp
```

---

### Cenário 3 — Atualizar plugins existentes

```bash
# Atualizar todos os plugins de uma vez:
sudo bash cacti-install.sh --update

# Atualizar um plugin específico:
sudo bash cacti-install.sh --plugin thold
sudo bash cacti-install.sh --plugin weathermap
```

---

### Cenário 4 — Gestão interativa de plugins

```bash
sudo bash cacti-plugin-manager.sh
# Abre menu interativo

# Ou não-interativo:
sudo bash cacti-plugin-manager.sh --status
sudo bash cacti-plugin-manager.sh --update
sudo bash cacti-plugin-manager.sh --install flowview
sudo bash cacti-plugin-manager.sh --remove weathermap
```

---

## Plugins instalados

| Plugin          | Função                                      |
|-----------------|---------------------------------------------|
| `thold`         | Fault Management — Alertas e thresholds     |
| `syslog`        | Log Management — Coleta de Syslog           |
| `maint`         | Maintenance Management — Janelas de manutenção |
| `monitor`       | Host Status Dashboard — Disponibilidade     |
| `hmib`          | SNMP Host MIB — Atributos MIB de hosts      |
| `webseer`       | Web Service Checks — Verificação HTTP/S     |
| `gexport`       | Graph Exports — Exportação de gráficos      |
| `intropage`     | Console Dashboard — Substitui o console     |
| `audit`         | Change Audit — Rastreamento de alterações   |
| `routerconfigs` | Router Configs — Backup de configurações    |
| `weathermap`    | Weathermap — Mapa de tráfego visual         |
| `flowview`      | FlowView — NetFlow/sFlow graphing           |

---

## Requisitos de sistema

| Recurso | Mínimo  | Recomendado |
|---------|---------|-------------|
| CPU     | 2 cores | 4+ cores    |
| RAM     | 2 GB    | 4–8 GB      |
| Disco   | 20 GB   | 40–80 GB    |
| OS      | Debian 11/12, Ubuntu 20.04/22.04/24.04 | Debian 12 |

---

## Portas de rede necessárias (Firewall)

| Porta     | Protocolo | Serviço         |
|-----------|-----------|-----------------|
| 80        | TCP       | HTTP (Cacti UI) |
| 443       | TCP       | HTTPS (opcional)|
| 161       | UDP       | SNMP polling    |
| 514       | UDP       | Syslog entrada  |
| 2055      | UDP       | NetFlow entrada |

---

## Após instalação — Ativar plugins

1. Acesse: `http://<IP>/cacti/`
2. Complete o wizard de instalação web
3. Vá a: **Console → Configuration → Plugin Management**
4. Ative cada plugin na lista
5. Alguns plugins precisam de configuração adicional:
   - **Syslog**: configurar dispositivos para enviar syslog para a porta UDP 514
   - **Flowview**: configurar dispositivos para enviar NetFlow para UDP 2055
   - **Routerconfigs**: configurar credenciais SSH/Telnet dos dispositivos
   - **Weathermap**: criar mapas em `Console → Weathermap`

---

## Configuração persistente

Após a primeira instalação, as credenciais são salvas em `.cacti-install.conf` no diretório dos scripts. Este ficheiro é carregado automaticamente em execuções subsequentes (útil para `--update`).

```bash
cat /opt/cacti-deploy/.cacti-install.conf
```

---

## Logs

```bash
# Log de instalação
tail -f /var/log/cacti-install.log

# Log de plugins
tail -f /var/log/cacti-plugins.log

# Log do poller Cacti
tail -f /var/www/html/cacti/log/cacti.log

# Log do poller cron
tail -f /var/log/cacti/poller.log
```

---

## Suporte a múltiplos nós Proxmox

Para instalar em múltiplas VMs em nós diferentes, repita o `proxmox-provision.sh` em cada nó com VMIDs diferentes, ou crie um loop:

```bash
NODES=("pve-node1" "pve-node2" "pve-node3")
VMID=200

for NODE in "${NODES[@]}"; do
  ssh root@${NODE} "bash /opt/cacti-deploy/proxmox-provision.sh --vmid ${VMID} --name cacti-${NODE}"
  ((VMID++))
done
```

---

## Contribuição / Personalização

- Para alterar versões dos plugins, edite `PLUGIN_BRANCHES` em `cacti-install.sh`
- Para adicionar novos plugins, adicione entradas em `PLUGIN_REPOS` e `PLUGIN_BRANCHES`
- O `cacti-plugin-manager.sh` suporta qualquer plugin no mesmo formato
