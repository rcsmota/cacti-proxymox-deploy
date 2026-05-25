# cacti-proxymox-deploy

Instalação e gestão automatizada do **Cacti 1.2.30 + Spine 1.2.30** com todos os plugins oficiais, em VMs Proxmox VE.

---

## Estrutura do repositório

```
cacti-proxymox-deploy/
├── cacti-deploy.conf.example   # Configuração central — copia e edita antes de usar
├── cacti-install.sh            # Instalador do Cacti + Spine + plugins (corre na VM)
├── proxmox-provision.sh        # Cria e provisiona a VM no host Proxmox
├── cacti-plugin-manager.sh     # Gestor interativo de plugins (pós-instalação)
└── README.md
```

---

## Início rápido

### 1. Clonar o repositório

No host Proxmox (ou na VM, se já existir):

```bash
git clone https://github.com/rcsmota/cacti-proxymox-deploy.git /opt/cacti-deploy
cd /opt/cacti-deploy
```

### 2. Configurar

```bash
cp cacti-deploy.conf.example cacti-deploy.conf
nano cacti-deploy.conf
```

Edita as secções que precisas — no mínimo as **senhas** e as **configurações de rede da VM**:

```bash
# Exemplo de configuração mínima
VMID=200
VM_NAME="Cacti"
VM_MEMORY=4096
VM_CORES=4
VM_DISK_SIZE=100
VM_STORAGE="local-lvm"
VM_BRIDGE="vmbr0"
VM_VLAN=120
VM_IP="192.168.120.100/24"
VM_GW="192.168.120.254"
VM_SSHKEY="/root/.ssh/id_rsa.pub"

CLOUD_USER="root"
CLOUD_PASS="senha-segura-da-vm"

CACTI_DB_PASS="senha-segura-do-banco"
CACTI_ADMIN_PASS="senha-segura-do-admin"
```

> ⚠️ O ficheiro `cacti-deploy.conf` está no `.gitignore` — as tuas senhas **nunca são enviadas para o GitHub**.

---

## Cenários de uso

### Cenário A — Criar VM nova no Proxmox + instalar tudo automaticamente

```bash
# No HOST Proxmox, como root:
cd /opt/cacti-deploy
bash proxmox-provision.sh
```

O script faz tudo:
1. Descarrega imagem cloud Debian 12
2. Cria a VM com as configurações do `.conf`
3. Configura cloud-init (rede, IP, SSH key)
4. Inicia a VM e transfere os scripts via SSH
5. Executa o `cacti-install.sh` automaticamente na VM

### Cenário B — VM já existente (Debian 11/12 ou Ubuntu 20.04/22.04/24.04)

```bash
# Na VM, como root:
cd /opt/cacti-deploy
bash cacti-install.sh
```

### Cenário C — Atualizar plugins

```bash
# Atualizar todos os plugins
bash cacti-install.sh --update

# Atualizar um plugin específico
bash cacti-install.sh --plugin thold
bash cacti-install.sh --plugin weathermap
```

---

## Plugins incluídos

| Plugin            | Função                                           |
|-------------------|--------------------------------------------------|
| `thold`           | Fault Management — Alertas e thresholds          |
| `syslog`          | Log Management — Coleta e análise de Syslog      |
| `maint`           | Maintenance Management — Janelas de manutenção   |
| `monitor`         | Host Status Dashboard — Painel de disponibilidade|
| `hmib`            | SNMP Host MIB — Monitoramento de atributos MIB   |
| `webseer`         | Web Service Checks — Verificação HTTP/S          |
| `gexport`         | Graph Exports — Exportação automática de gráficos|
| `intropage`       | Console Dashboard — Substitui o console Cacti    |
| `audit`           | Change Audit — Rastreamento de alterações        |
| `routerconfigs`   | Router Configs — Backup de configurações         |
| `weathermap`      | Weathermap — Mapa visual de tráfego de rede      |
| `flowview`        | FlowView — NetFlow/sFlow graphing                |

Todos os plugins são clonados diretamente dos repositórios oficiais em [github.com/Cacti](https://github.com/Cacti).

---

## Gestão de plugins (pós-instalação)

```bash
# Menu interativo
sudo bash cacti-plugin-manager.sh

# Não-interativo
sudo bash cacti-plugin-manager.sh --status          # Ver estado de todos
sudo bash cacti-plugin-manager.sh --update          # Atualizar todos
sudo bash cacti-plugin-manager.sh --install flowview
sudo bash cacti-plugin-manager.sh --remove weathermap
```

---

## Requisitos

### Host Proxmox
- Proxmox VE 7.x ou 8.x
- Acesso root ao host
- Chave SSH configurada (`/root/.ssh/id_rsa.pub`)

### VM (criada automaticamente ou existente)
| Recurso | Mínimo  | Recomendado |
|---------|---------|-------------|
| CPU     | 2 cores | 4+ cores    |
| RAM     | 2 GB    | 4–8 GB      |
| Disco   | 20 GB   | 40–100 GB   |
| OS      | Debian 11/12, Ubuntu 20.04/22.04/24.04 | Debian 12 |

---

## Portas de rede necessárias

| Porta  | Protocolo | Serviço              |
|--------|-----------|----------------------|
| 80     | TCP       | Interface web Cacti  |
| 443    | TCP       | HTTPS (opcional)     |
| 161    | UDP       | SNMP polling         |
| 514    | UDP       | Syslog (plugin)      |
| 2055   | UDP       | NetFlow (FlowView)   |

---

## Após instalação

1. Acede a `http://<IP-DA-VM>/cacti/`
2. Completa o wizard de instalação web
3. Vai a **Console → Configuration → Plugin Management**
4. Ativa os plugins que precisas

### Configuração adicional por plugin

- **Syslog** — Configura os dispositivos para enviar syslog para `UDP 514` na IP do Cacti
- **FlowView** — Configura os dispositivos para enviar NetFlow/sFlow para `UDP 2055`
- **RouterConfigs** — Adiciona as credenciais SSH/Telnet dos dispositivos em `Console → RouterConfigs`
- **Weathermap** — Cria os mapas em `Console → Weathermap Editor`

---

## Acompanhar a instalação

```bash
# Log em tempo real na VM
ssh root@192.168.120.100 'tail -f /var/log/cacti-install.log'

# Log do poller Cacti
tail -f /var/www/html/cacti/log/cacti.log

# Log do cron
tail -f /var/log/cacti/poller.log
```

---

## Deploy em múltiplos nós Proxmox

```bash
for NODE in pve-node1 pve-node2 pve-node3; do
  scp -r /opt/cacti-deploy root@${NODE}:/opt/
  ssh root@${NODE} "cd /opt/cacti-deploy && bash proxmox-provision.sh"
done
```

---

## Configuração dos plugins (branches)

Por padrão todos os plugins usam o branch `develop` (versão mais recente).
Para fixar uma versão específica, edita o `cacti-deploy.conf`:

```bash
PLUGIN_BRANCH_THOLD="1.2"
PLUGIN_BRANCH_WEATHERMAP="develop"
```
