#!/usr/bin/env bash
#
# create-redis-lxc.sh
# Cria LXC AlmaLinux 10 com Valkey (Redis-compatible) pronto pra uso (Vitrum / Rodojunior)
#
# NOTA: AlmaLinux/RHEL 10 substituiu o pacote redis pelo valkey (fork drop-in,
# mesmo protocolo, mesmo RDB/AOF). Clientes ioredis/Bull funcionam sem mudanças.
#
# Uso:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/RodoJuniorGit/RodoScripts/refs/heads/main/create-redis-lxc.sh)"
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
echo "  Redis (Valkey) LXC - AlmaLinux 10 - Rodojunior"
echo "============================================================"
echo

read -rp "VMID                              [110]: " VMID
VMID="${VMID:-110}"

if pct status "${VMID}" &>/dev/null; then
  err "VMID ${VMID} já existe. Aborte ou destrua antes: pct destroy ${VMID}"
  exit 1
fi

read -rp "Hostname                          [redis-prod]: " HOSTNAME
HOSTNAME="${HOSTNAME:-redis-prod}"

while true; do
  read -rp "IP em CIDR (ex: 10.1.1.196/24)    : " IP
  if [[ "${IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then break; fi
  warn "Formato inválido. Use algo como 10.1.1.196/24"
done

read -rp "Gateway                           [10.1.1.1]: " GATEWAY
GATEWAY="${GATEWAY:-10.1.1.1}"

read -rp "Bridge                            [vmbr0]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"

read -rp "Storage                           [local-lvm]: " STORAGE
STORAGE="${STORAGE:-local-lvm}"

read -rp "Disco em GB                       [8]: " DISK_SIZE
DISK_SIZE="${DISK_SIZE:-8}"

read -rp "Cores                             [2]: " CORES
CORES="${CORES:-2}"

read -rp "RAM em MB                         [2048]: " MEMORY
MEMORY="${MEMORY:-2048}"

read -rp "Swap em MB                        [512]: " SWAP
SWAP="${SWAP:-512}"

# maxmemory do Redis: deixa folga pra fork do AOF-rewrite (~50-60% da RAM do CT)
DEFAULT_MAXMEM=$(( MEMORY * 55 / 100 ))
read -rp "Redis maxmemory em MB             [${DEFAULT_MAXMEM}]: " REDIS_MAXMEM
REDIS_MAXMEM="${REDIS_MAXMEM:-${DEFAULT_MAXMEM}}"

# Senha do root do container
while true; do
  read -rsp "Senha root do CONTAINER           : " ROOT_PASS; echo
  read -rsp "Confirme                          : " ROOT_PASS2; echo
  [[ "${ROOT_PASS}" == "${ROOT_PASS2}" && -n "${ROOT_PASS}" ]] && break
  warn "Senhas não conferem ou estão vazias."
done

# Senha do Redis (requirepass)
while true; do
  read -rsp "Senha do Redis (requirepass)      : " REDIS_PASS; echo
  read -rsp "Confirme                          : " REDIS_PASS2; echo
  [[ "${REDIS_PASS}" == "${REDIS_PASS2}" && -n "${REDIS_PASS}" ]] && break
  warn "Senhas não conferem ou estão vazias."
done

echo
msg "Resumo:"
cat <<EOF
  VMID:           ${VMID}
  Hostname:       ${HOSTNAME}
  IP/Gateway:     ${IP} via ${GATEWAY} em ${BRIDGE}
  Storage/Disco:  ${STORAGE} / ${DISK_SIZE}G
  CPU/RAM/Swap:   ${CORES}c / ${MEMORY}M / ${SWAP}M
  maxmemory:      ${REDIS_MAXMEM}M (policy: noeviction - obrigatório pro Bull)
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
  --description "Redis (Valkey) - ${HOSTNAME}
OS: AlmaLinux 10
Provisioned: $(date -Iseconds)"

ok "LXC criado"

msg "Iniciando container..."
pct start "${VMID}"
sleep 8

# ─── Bootstrap dentro do CT ───────────────────────────────────────────────────
msg "Instalando Valkey no container..."

pct exec "${VMID}" -- bash -s <<BOOTSTRAP
set -euo pipefail

dnf -y update
dnf -y install epel-release
dnf -y install curl vim-enhanced bash-completion logrotate firewalld valkey valkey-compat-redis 2>/dev/null \
  || dnf -y install curl vim-enhanced bash-completion logrotate firewalld valkey

# valkey-compat-redis cria symlinks redis-cli/redis-server; se não existir, segue só com valkey-*
command -v valkey-server >/dev/null || { echo "FALHA: valkey-server não encontrado após install"; exit 1; }

# NOTA: vm.overcommit_memory e THP são sysctls do HOST - não configuráveis em
# LXC unprivileged. Recomendado no host Proxmox: sysctl -w vm.overcommit_memory=1

# ─── Configuração ─────────────────────────────────────────────────────────────
cat > /etc/valkey/valkey.conf <<CONF
# Rede
bind 0.0.0.0
port 6379
protected-mode yes
requirepass ${REDIS_PASS}

# Persistência (AOF + RDB de segurança)
dir /var/lib/valkey
appendonly yes
appendfsync everysec
save 900 1
save 300 100

# Memória - noeviction é OBRIGATÓRIO pro Bull (evita corromper estado de fila)
maxmemory ${REDIS_MAXMEM}mb
maxmemory-policy noeviction

# Logging
logfile /var/log/valkey/valkey.log
loglevel notice

# Segurança extra - desabilita comandos perigosos
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG "CONFIG_a7f3k9"
rename-command SHUTDOWN "SHUTDOWN_a7f3k9"
CONF

chown valkey:valkey /etc/valkey/valkey.conf
chmod 640 /etc/valkey/valkey.conf

systemctl enable --now valkey

# Aguarda subir
for i in {1..15}; do
  if valkey-cli -a '${REDIS_PASS}' --no-auth-warning ping 2>/dev/null | grep -q PONG; then break; fi
  sleep 2
done

valkey-cli -a '${REDIS_PASS}' --no-auth-warning ping | grep -q PONG \
  || { echo "FALHA: Valkey não respondeu ao PING"; exit 1; }

# ─── Firewall ─────────────────────────────────────────────────────────────────
systemctl enable --now firewalld
firewall-cmd --permanent --new-zone=rodo 2>/dev/null || true
firewall-cmd --permanent --zone=rodo --add-source=10.1.1.0/24
firewall-cmd --permanent --zone=rodo --add-port=6379/tcp
firewall-cmd --permanent --zone=rodo --add-service=ssh
firewall-cmd --reload

echo
echo "Valkey versão:"
valkey-server --version
BOOTSTRAP

ok "Bootstrap concluído"

# ─── Resumo final ─────────────────────────────────────────────────────────────
IP_ONLY="${IP%/*}"
echo
echo "============================================================"
ok "LXC ${VMID} (${HOSTNAME}) provisionado"
echo "============================================================"
cat <<EOF

  Conexão:        redis://:<senha>@${IP_ONLY}:6379
  maxmemory:      ${REDIS_MAXMEM}mb (noeviction)
  Persistência:   AOF everysec + RDB em /var/lib/valkey

  Snapshot inicial recomendado:
    pct snapshot ${VMID} clean-install

  Acesso ao container:
    pct enter ${VMID}

  ── Migração dos dados da nuvem ──────────────────────────────
  Opção 1 - REPLICAOF (se o provedor permitir; ElastiCache NÃO permite):
    pct exec ${VMID} -- valkey-cli -a '<senha>' --no-auth-warning \\
      REPLICAOF <host-nuvem> 6379
    pct exec ${VMID} -- valkey-cli -a '<senha>' --no-auth-warning \\
      CONFIG_a7f3k9 SET masterauth '<senha-da-nuvem>'
    # confere INFO replication (master_link_status:up), depois promove:
    pct exec ${VMID} -- valkey-cli -a '<senha>' --no-auth-warning REPLICAOF NO ONE

  Opção 2 - Dump RDB (ElastiCache / mais simples):
    redis-cli -h <host-nuvem> -a '<senha-nuvem>' --rdb /tmp/dump.rdb
    pct exec ${VMID} -- systemctl stop valkey
    pct push ${VMID} /tmp/dump.rdb /var/lib/valkey/dump.rdb
    pct exec ${VMID} -- chown valkey:valkey /var/lib/valkey/dump.rdb
    pct exec ${VMID} -- systemctl start valkey
    # (com appendonly yes, o AOF é reconstruído a partir do RDB no primeiro boot)

  Depois: atualiza REDIS_HOST/REDIS_URL nas envs do Dokploy e redeploya.

EOF
