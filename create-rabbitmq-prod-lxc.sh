#!/usr/bin/env bash
#
# create-rabbitmq-prod-lxc.sh
# Cria LXC AlmaLinux 10 com RabbitMQ pronto pra uso - PRODUÇÃO (Vitrum / Rodojunior)
#
# Uso:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/RodoJuniorGit/RodoScripts/refs/heads/main/create-rabbitmq-prod-lxc.sh)"
#
set -euo pipefail

# ─── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
msg()  { echo -e "${BLUE}>>>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

# ─── Pré-checks ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { err "Rode como root no host Proxmox."; exit 1; }
command -v pct >/dev/null || { err "pct não encontrado. Esse script é pra rodar no host Proxmox."; exit 1; }
command -v pveam >/dev/null || { err "pveam não encontrado."; exit 1; }

# ─── Prompts ──────────────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  RabbitMQ LXC - AlmaLinux 10 - Rodojunior [PRODUÇÃO]"
echo "============================================================"
echo

read -rp "VMID                              [108]: " VMID
VMID="${VMID:-108}"

if pct status "${VMID}" &>/dev/null; then
  err "VMID ${VMID} já existe. Aborte ou destrua antes: pct destroy ${VMID}"
  exit 1
fi

read -rp "Hostname                          [rabbitmq-prod]: " HOSTNAME
HOSTNAME="${HOSTNAME:-rabbitmq-prod}"

while true; do
  read -rp "IP em CIDR (ex: 10.1.1.190/24)    : " IP
  if [[ "${IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then break; fi
  warn "Formato inválido. Use algo como 10.1.1.190/24"
done

read -rp "Gateway                           [10.1.1.1]: " GATEWAY
GATEWAY="${GATEWAY:-10.1.1.1}"

read -rp "Bridge                            [vmbr0]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"

read -rp "Storage                           [local-lvm]: " STORAGE
STORAGE="${STORAGE:-local-lvm}"

read -rp "Disco em GB                       [32]: " DISK_SIZE
DISK_SIZE="${DISK_SIZE:-32}"

read -rp "Cores                             [4]: " CORES
CORES="${CORES:-4}"

read -rp "RAM em MB                         [8192]: " MEMORY
MEMORY="${MEMORY:-8192}"

read -rp "Swap em MB                        [1024]: " SWAP
SWAP="${SWAP:-1024}"

# Senha do root do container
while true; do
  read -rsp "Senha root do CONTAINER           : " ROOT_PASS; echo
  read -rsp "Confirme                          : " ROOT_PASS2; echo
  [[ "${ROOT_PASS}" == "${ROOT_PASS2}" && -n "${ROOT_PASS}" ]] && break
  warn "Senhas não conferem ou estão vazias."
done

# Usuário admin do RabbitMQ
read -rp "Usuário admin RabbitMQ            [vitrum]: " RMQ_USER
RMQ_USER="${RMQ_USER:-vitrum}"

while true; do
  read -rsp "Senha admin RabbitMQ              : " RMQ_PASS; echo
  read -rsp "Confirme                          : " RMQ_PASS2; echo
  [[ "${RMQ_PASS}" == "${RMQ_PASS2}" && -n "${RMQ_PASS}" ]] && break
  warn "Senhas não conferem ou estão vazias."
done

read -rp "VHost adicional (vazio = só o /)  []: " RMQ_VHOST

echo
msg "Resumo:"
cat <<EOF
  VMID:           ${VMID}
  Hostname:       ${HOSTNAME}
  IP/Gateway:     ${IP} via ${GATEWAY} em ${BRIDGE}
  Storage/Disco:  ${STORAGE} / ${DISK_SIZE}G
  CPU/RAM/Swap:   ${CORES}c / ${MEMORY}M / ${SWAP}M
  RabbitMQ user:  ${RMQ_USER}
  VHost extra:    ${RMQ_VHOST:-<nenhum>}
EOF
read -rp "Prosseguir? [s/N]: " CONFIRM
[[ "${CONFIRM,,}" == "s" ]] || { warn "Cancelado."; exit 0; }

# ─── Template AlmaLinux 10 (descobre o mais novo) ─────────────────────────────
msg "Procurando template AlmaLinux 10 mais recente..."
TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
  | awk '/almalinux-10-default/ {print $2}' \
  | sort -V | tail -1)

if [[ -z "${TEMPLATE_NAME}" ]]; then
  err "Nenhum template almalinux-10-default disponível em 'pveam available'."
  exit 1
fi
ok "Template alvo: ${TEMPLATE_NAME}"

if ! pveam list local 2>/dev/null | grep -q "${TEMPLATE_NAME}"; then
  msg "Baixando template..."
  pveam download local "${TEMPLATE_NAME}"
else
  ok "Template já presente em local"
fi

TEMPLATE="local:vztmpl/${TEMPLATE_NAME}"

# ─── Cria LXC ─────────────────────────────────────────────────────────────────
msg "Criando LXC ${VMID}..."
pct create "${VMID}" "${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY},firewall=1" \
  --nameserver "1.1.1.1 8.8.8.8" \
  --unprivileged 1 \
  --features "nesting=1" \
  --onboot 1 \
  --password "${ROOT_PASS}" \
  --description "RabbitMQ [PROD] - ${HOSTNAME}
OS: AlmaLinux 10
Provisioned: $(date -Iseconds)"

ok "LXC criado"

msg "Iniciando container..."
pct start "${VMID}"
sleep 8

# ─── Bootstrap dentro do CT ───────────────────────────────────────────────────
msg "Instalando RabbitMQ no container (pode demorar uns minutos)..."

pct exec "${VMID}" -- bash -s <<BOOTSTRAP
set -euo pipefail

dnf -y update
dnf -y install epel-release
dnf -y install curl vim-enhanced bash-completion logrotate firewalld

# NOTA: chrony removido - LXC unprivileged não tem CAP_SYS_TIME, herda hora do host
# NOTA: SELinux já é gerenciado pelo Proxmox no CT

# Repo RabbitMQ - usa el/9 (oficialmente compatível com EL10 conforme rabbitmq team)
cat > /etc/yum.repos.d/rabbitmq.repo <<'REPO'
[modern-erlang]
name=modern-erlang
baseurl=https://yum1.rabbitmq.com/erlang/el/9/\$basearch
       https://yum2.rabbitmq.com/erlang/el/9/\$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-server]
name=rabbitmq-server
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/\$basearch
       https://yum1.rabbitmq.com/rabbitmq/el/9/\$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md
REPO

dnf -y install erlang rabbitmq-server

# Verificação explícita
command -v rabbitmqctl >/dev/null || { echo "FALHA: rabbitmqctl não encontrado após install"; exit 1; }
command -v erl >/dev/null || { echo "FALHA: erlang não encontrado após install"; exit 1; }

mkdir -p /etc/rabbitmq
cat > /etc/rabbitmq/rabbitmq.conf <<'CONF'
# Memory
vm_memory_high_watermark.relative = 0.6
vm_memory_high_watermark_paging_ratio = 0.75

# Disk
disk_free_limit.relative = 1.5

# Logging
log.console = true
log.console.level = info
log.file = true
log.file.level = info

# Listeners
listeners.tcp.default = 5672
management.tcp.port = 15672

# Default user (guest) só funciona em localhost por segurança - manter
loopback_users.guest = true
CONF

rabbitmq-plugins enable --offline rabbitmq_management rabbitmq_prometheus

systemctl enable --now rabbitmq-server

# Aguarda subir
for i in {1..30}; do
  if rabbitmqctl -q status >/dev/null 2>&1; then break; fi
  sleep 2
done

# Cria admin e remove guest
rabbitmqctl add_user '${RMQ_USER}' '${RMQ_PASS}'
rabbitmqctl set_user_tags '${RMQ_USER}' administrator
rabbitmqctl set_permissions -p / '${RMQ_USER}' '.*' '.*' '.*'
rabbitmqctl delete_user guest || true

# VHost extra opcional
if [[ -n '${RMQ_VHOST}' ]]; then
  rabbitmqctl add_vhost '${RMQ_VHOST}'
  rabbitmqctl set_permissions -p '${RMQ_VHOST}' '${RMQ_USER}' '.*' '.*' '.*'
fi

# Firewall
systemctl enable --now firewalld
firewall-cmd --permanent --new-zone=rodo 2>/dev/null || true
firewall-cmd --permanent --zone=rodo --add-source=10.1.1.0/24
firewall-cmd --permanent --zone=rodo --add-port=5672/tcp
firewall-cmd --permanent --zone=rodo --add-port=15672/tcp
firewall-cmd --permanent --zone=rodo --add-port=15692/tcp
firewall-cmd --permanent --zone=rodo --add-service=ssh
firewall-cmd --reload

echo
echo "RabbitMQ versão:"
rabbitmqctl -q version
BOOTSTRAP

ok "Bootstrap concluído"

# ─── Resumo final ─────────────────────────────────────────────────────────────
IP_ONLY="${IP%/*}"
echo
echo "============================================================"
ok "LXC ${VMID} (${HOSTNAME}) provisionado [PROD]"
echo "============================================================"
cat <<EOF

  Management UI:  http://${IP_ONLY}:15672
  Prometheus:     http://${IP_ONLY}:15692/metrics
  AMQP:           amqp://${RMQ_USER}@${IP_ONLY}:5672/
  Admin user:     ${RMQ_USER}
  VHost extra:    ${RMQ_VHOST:-<nenhum, só o "/" default>}

  Snapshot inicial recomendado:
    pct snapshot ${VMID} clean-install

  Acesso ao container:
    pct enter ${VMID}

EOF