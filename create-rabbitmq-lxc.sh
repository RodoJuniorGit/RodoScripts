#!/usr/bin/env bash
#
# Cria LXC AlmaLinux 10 para RabbitMQ HML
# Rodar no host Proxmox (rodojunior)
#
set -euo pipefail

VMID=109
HOSTNAME="rabbitmq-hml"
TEMPLATE="local:vztmpl/almalinux-10-default_20250930_amd64.tar.xz"
STORAGE="local-lvm"
DISK_SIZE="16"
CORES=2
MEMORY=4096
SWAP=512
IP="10.1.1.12/24"           # <-- AJUSTAR antes de rodar
GATEWAY="10.1.1.1"         # <-- conferir
BRIDGE="vmbr0"
PASSWORD="trocardps"   # <-- root inicial, troca depois ou usa SSH key
SSH_KEY_FILE=""            # <-- opcional, ex: /root/.ssh/id_ed25519.pub

echo ">>> Criando LXC ${VMID} (${HOSTNAME})"

ARGS=(
  "${VMID}"
  "${TEMPLATE}"
  --hostname "${HOSTNAME}"
  --cores "${CORES}"
  --memory "${MEMORY}"
  --swap "${SWAP}"
  --rootfs "${STORAGE}:${DISK_SIZE}"
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY},firewall=1"
  --nameserver "1.1.1.1 8.8.8.8"
  --unprivileged 1
  --features "nesting=1"
  --onboot 1
  --password "${PASSWORD}"
  --description "RabbitMQ HML - Vitrum
Managed: manual setup
OS: AlmaLinux 10"
)

if [[ -n "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}" ]]; then
  ARGS+=(--ssh-public-keys "${SSH_KEY_FILE}")
fi

pct create "${ARGS[@]}"

echo ">>> Iniciando container"
pct start "${VMID}"

echo ">>> Aguardando network..."
sleep 8

echo ">>> Bootstrap dentro do container"
pct exec "${VMID}" -- bash -c '
set -euo pipefail

# Update base + tools úteis
dnf -y update
dnf -y install epel-release
dnf -y install curl vim-enhanced bash-completion chrony logrotate firewalld policycoreutils-python-utils

systemctl enable --now chronyd

# Repo RabbitMQ (usa el/9 - oficialmente compatível com EL10 segundo o time do RabbitMQ)
cat > /etc/yum.repos.d/rabbitmq.repo << "EOF"
##
## Zero dependency Erlang RPM
##
[modern-erlang]
name=modern-erlang
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
       https://yum2.rabbitmq.com/erlang/el/9/$basearch
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

##
## RabbitMQ server
##
[rabbitmq-server]
name=rabbitmq-server
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/$basearch
       https://yum1.rabbitmq.com/rabbitmq/el/9/$basearch
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
EOF

dnf -y install erlang rabbitmq-server

# Config base - watermark de memória e logs
mkdir -p /etc/rabbitmq
cat > /etc/rabbitmq/rabbitmq.conf << "EOF"
# === Memory ===
vm_memory_high_watermark.relative = 0.6
vm_memory_high_watermark_paging_ratio = 0.75

# === Disk ===
disk_free_limit.relative = 1.5

# === Logging ===
log.console = true
log.console.level = info
log.file = true
log.file.level = info

# === Listeners ===
listeners.tcp.default = 5672
management.tcp.port = 15672
EOF

# Habilita plugins essenciais
rabbitmq-plugins enable --offline rabbitmq_management rabbitmq_prometheus

systemctl enable --now rabbitmq-server

# Firewall: libera amqp + management + prometheus na rede interna
firewall-offline-cmd --set-default-zone=internal || true
firewall-offline-cmd --zone=internal --add-source=10.1.1.0/24 || true
firewall-offline-cmd --zone=internal --add-port=5672/tcp || true
firewall-offline-cmd --zone=internal --add-port=15672/tcp || true
firewall-offline-cmd --zone=internal --add-port=15692/tcp || true
firewall-offline-cmd --zone=internal --add-service=ssh || true
systemctl enable --now firewalld

echo ">>> RabbitMQ instalado. Versão:"
rabbitmqctl version || true
echo ">>> Status:"
systemctl status rabbitmq-server --no-pager -l | head -20
'

echo
echo "================================================"
echo " LXC ${VMID} (${HOSTNAME}) pronto"
echo "================================================"
echo " IP:           ${IP%/*}"
echo " Management:   http://${IP%/*}:15672  (user/pass: guest/guest - SÓ localhost)"
echo " Prometheus:   http://${IP%/*}:15692/metrics"
echo " AMQP:         amqp://${IP%/*}:5672"
echo
echo " PRÓXIMOS PASSOS (rodar dentro do container com 'pct enter ${VMID}'):"
echo "   1) Criar usuário admin e remover guest:"
echo "      rabbitmqctl add_user vitrum '<SENHA_FORTE>'"
echo "      rabbitmqctl set_user_tags vitrum administrator"
echo "      rabbitmqctl set_permissions -p / vitrum '.*' '.*' '.*'"
echo "      rabbitmqctl delete_user guest"
echo
echo "   2) Criar vhost de homologação se quiser isolar:"
echo "      rabbitmqctl add_vhost vitrum-hml"
echo "      rabbitmqctl set_permissions -p vitrum-hml vitrum '.*' '.*' '.*'"
echo
echo "   3) Snapshot inicial no Proxmox:"
echo "      pct snapshot ${VMID} clean-install"
echo "================================================"