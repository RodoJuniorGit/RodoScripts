#!/usr/bin/env bash
# =============================================================================
# AlmaLinux 10 VM Creator for Proxmox
# Creates a q35/OVMF VM with cloud-init, SSH key, and static IP
# Storage: ssd-nvme (LVM)
# Network: 10.1.1.0/24 via vmbr0
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
STORAGE="ssd-nvme"
BRIDGE="vmbr0"
GATEWAY="10.1.1.1"
DNS="8.8.8.8 8.8.4.4"
CIDR="/24"
STATIC_IP=""
IMAGE_URL="https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
IMAGE_DIR="/var/lib/vz/template/iso"
IMAGE_FILE="AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
SSH_KEY_DIR="/root/.ssh/proxmox-vm-keys"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then err "Run as root."; fi

# ── Get next available VMID ───────────────────────────────────────────────────
get_next_vmid() {
  local id
  id=$(pvesh get /cluster/nextid)
  while [[ -f "/etc/pve/qemu-server/${id}.conf" ]] || [[ -f "/etc/pve/lxc/${id}.conf" ]]; do
    id=$((id + 1))
  done
  echo "$id"
}

# ── Generate SSH key pair ─────────────────────────────────────────────────────
generate_ssh_key() {
  local hostname="$1"
  local key_path="${SSH_KEY_DIR}/${hostname}"

  mkdir -p "$SSH_KEY_DIR"
  chmod 700 "$SSH_KEY_DIR"

  if [[ -f "${key_path}" ]]; then
    warn "SSH key already exists at ${key_path}, reusing it."
  else
    ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "proxmox-${hostname}" >/dev/null 2>&1
    ok "Generated SSH key pair at ${key_path}"
  fi

  SSH_PRIVATE_KEY="${key_path}"
  SSH_PUBLIC_KEY="${key_path}.pub"
}

# ── Ensure dependencies ───────────────────────────────────────────────────────
ensure_deps() {
  if ! command -v virt-customize &>/dev/null; then
    info "Installing libguestfs-tools..."
    apt-get -qq update >/dev/null 2>&1
    apt-get -qq install -y libguestfs-tools >/dev/null 2>&1
    ok "Installed libguestfs-tools"
  fi
}

# ── Download image if not cached ─────────────────────────────────────────────
download_image() {
  mkdir -p "$IMAGE_DIR"
  if [[ -f "${IMAGE_DIR}/${IMAGE_FILE}" ]]; then
    ok "Image already cached at ${IMAGE_DIR}/${IMAGE_FILE}"
  else
    info "Downloading AlmaLinux 10 cloud image..."
    curl -fSL -o "${IMAGE_DIR}/${IMAGE_FILE}" "$IMAGE_URL"
    ok "Downloaded image"
  fi
}

# ── Prompt for parameters ────────────────────────────────────────────────────
prompt_params() {
  VMID=$(get_next_vmid)

  echo -e "\n${BOLD}═══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  AlmaLinux 10 VM Creator${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}\n"

  echo -e "Next available VMID: ${CYAN}${VMID}${NC}\n"

  # Hostname
  read -rp "Hostname [almalinux]: " HN
  HN="${HN:-almalinux}"
  HN=$(echo "${HN,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')

  # CPU Cores
  read -rp "CPU Cores [2]: " CORES
  CORES="${CORES:-2}"
  if [[ ! "$CORES" =~ ^[1-9][0-9]*$ ]]; then err "Invalid core count"; fi

  # RAM
  read -rp "RAM in MB [2048]: " RAM
  RAM="${RAM:-2048}"
  if [[ ! "$RAM" =~ ^[1-9][0-9]*$ ]]; then err "Invalid RAM size"; fi

  # Disk size
  read -rp "Disk size in GB [20]: " DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-20}"
  if [[ ! "$DISK_SIZE" =~ ^[1-9][0-9]*$ ]]; then err "Invalid disk size"; fi

  # Static IP (blank = DHCP)
  read -rp "Static IP [DHCP]: " STATIC_IP
  if [[ -n "$STATIC_IP" ]]; then
    if [[ ! "$STATIC_IP" =~ ^10\.1\.1\.[0-9]+$ ]]; then err "IP must be in 10.1.1.0/24 range"; fi
    IP_DISPLAY="$STATIC_IP"
  else
    IP_DISPLAY="DHCP"
  fi

  # Root password (for console access fallback)
  read -rsp "Root password: " ROOT_PASS
  echo ""
  if [[ -z "$ROOT_PASS" ]]; then err "Password is required"; fi

  # Confirm
  echo -e "\n${BOLD}── Summary ─────────────────────────────────────${NC}"
  echo -e "  VMID:     ${CYAN}${VMID}${NC}"
  echo -e "  Hostname: ${CYAN}${HN}${NC}"
  echo -e "  Cores:    ${CYAN}${CORES}${NC}"
  echo -e "  RAM:      ${CYAN}${RAM} MB${NC}"
  echo -e "  Disk:     ${CYAN}${DISK_SIZE} GB${NC}"
  echo -e "  IP:       ${CYAN}${IP_DISPLAY}${NC}"
  echo -e "  Storage:  ${CYAN}${STORAGE}${NC}"
  echo -e "${BOLD}─────────────────────────────────────────────────${NC}\n"

  read -rp "Proceed? [Y/n]: " CONFIRM
  if [[ "${CONFIRM,,}" == "n" ]]; then
    exit 0
  fi
}

# ── Create the VM ─────────────────────────────────────────────────────────────
create_vm() {
  local mac
  mac="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g;s/:$//' | tr '[:lower:]' '[:upper:]')"

  info "Generating SSH key pair..."
  generate_ssh_key "$HN"

  info "Preparing work image..."
  local work_file
  work_file=$(mktemp --suffix=.qcow2)
  cp "${IMAGE_DIR}/${IMAGE_FILE}" "$work_file"

  info "Customizing image..."
  virt-customize -q -a "$work_file" --hostname "$HN" >/dev/null 2>&1
  virt-customize -q -a "$work_file" --run-command "truncate -s 0 /etc/machine-id" >/dev/null 2>&1
  virt-customize -q -a "$work_file" --run-command "rm -f /var/lib/dbus/machine-id" >/dev/null 2>&1
  virt-customize -q -a "$work_file" --run-command "systemctl disable systemd-firstboot.service 2>/dev/null; ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service" >/dev/null 2>&1 || true
  virt-customize -q -a "$work_file" --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" >/dev/null 2>&1 || true
  virt-customize -q -a "$work_file" --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" >/dev/null 2>&1 || true
  virt-customize -q -a "$work_file" --run-command "systemctl enable serial-getty@ttyS0.service" >/dev/null 2>&1 || true
  virt-customize -q -a "$work_file" --selinux-relabel >/dev/null 2>&1 || true
  ok "Image customized"

  info "Converting to raw format (required for LVM)..."
  local raw_file
  raw_file=$(mktemp --suffix=.raw)
  qemu-img convert -f qcow2 -O raw "$work_file" "$raw_file"
  rm -f "$work_file"
  ok "Converted to raw"

  info "Creating VM ${VMID}..."
  qm create "$VMID" \
    -agent 1 \
    -machine q35 \
    -tablet 0 \
    -localtime 1 \
    -bios ovmf \
    -cpu x86-64-v3 \
    -cores "$CORES" \
    -memory "$RAM" \
    -name "$HN" \
    -net0 "virtio,bridge=${BRIDGE},macaddr=${mac}" \
    -onboot 1 \
    -ostype l26 \
    -scsihw virtio-scsi-pci

  # Allocate EFI and TPM disks
  pvesm alloc "$STORAGE" "$VMID" "vm-${VMID}-disk-0" 4M >/dev/null
  pvesm alloc "$STORAGE" "$VMID" "vm-${VMID}-disk-2" 4M >/dev/null

  # Import the OS disk
  info "Importing disk image..."
  qm importdisk "$VMID" "$raw_file" "$STORAGE" -format raw >/dev/null
  rm -f "$raw_file"

  # Configure disks and boot
  qm set "$VMID" \
    -efidisk0 "${STORAGE}:vm-${VMID}-disk-0" \
    -scsi0 "${STORAGE}:vm-${VMID}-disk-1,discard=on,ssd=1" \
    -scsi1 "${STORAGE}:cloudinit" \
    -tpmstate0 "${STORAGE}:vm-${VMID}-disk-2,version=v2.0" \
    -boot order=scsi0 \
    -serial0 socket >/dev/null

  # Resize disk
  info "Resizing disk to ${DISK_SIZE}G..."
  qm resize "$VMID" scsi0 "${DISK_SIZE}G" >/dev/null

  # Configure cloud-init
  info "Configuring cloud-init..."
  local ipconfig
  if [[ -n "$STATIC_IP" ]]; then
    ipconfig="ip=${STATIC_IP}${CIDR},gw=${GATEWAY}"
  else
    ipconfig="ip=dhcp"
  fi

  # Create cloud-init vendor snippet to install qemu-guest-agent
  local snippets_dir="/var/lib/vz/snippets"
  mkdir -p "$snippets_dir"
  cat > "${snippets_dir}/vm-${VMID}-vendor.yaml" <<'VENDOREOF'
#cloud-config
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
VENDOREOF

  qm set "$VMID" \
    --ciuser root \
    --cipassword "$ROOT_PASS" \
    --ipconfig0 "$ipconfig" \
    --nameserver "$(echo $DNS | awk '{print $1}')" \
    --searchdomain "" \
    --sshkeys "$SSH_PUBLIC_KEY" \
    --ciupgrade 0 \
    --cicustom "vendor=local:snippets/vm-${VMID}-vendor.yaml" >/dev/null

  ok "Created VM ${VMID} (${HN})"

  # Start the VM
  info "Starting VM..."
  qm start "$VMID"
  ok "VM started"

  # Wait for VM to come up
  if [[ -n "$STATIC_IP" ]]; then
    info "Waiting for ${STATIC_IP} to respond..."
    local retries=0
    while ! ping -c 1 -W 1 "$STATIC_IP" &>/dev/null; do
      retries=$((retries + 1))
      if [[ $retries -ge 60 ]]; then
        warn "VM did not respond after 60s. Check console with: qm terminal ${VMID}"
        break
      fi
      sleep 1
    done
    if [[ $retries -lt 60 ]]; then ok "VM is online at ${STATIC_IP}"; fi
  else
    info "VM is using DHCP. Waiting for qemu-guest-agent to report IP..."
    local retries=0
    local vm_ip=""
    while [[ -z "$vm_ip" ]]; do
      vm_ip=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
        | grep -oP '"ip-address"\s*:\s*"10\.1\.1\.\d+"' \
        | head -1 \
        | grep -oP '10\.1\.1\.\d+' || true)
      retries=$((retries + 1))
      if [[ $retries -ge 90 ]]; then
        warn "Could not detect IP after 90s. Check console with: qm terminal ${VMID}"
        break
      fi
      sleep 1
    done
    if [[ -n "$vm_ip" ]]; then
      STATIC_IP="$vm_ip"
      ok "VM is online at ${vm_ip} (via DHCP)"
    fi
  fi
}

# ── Print summary ────────────────────────────────────────────────────────────
print_summary() {
  local ssh_target="${STATIC_IP:-<check DHCP lease>}"

  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  VM Created Successfully${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  SSH:  ${CYAN}ssh -i ${SSH_PRIVATE_KEY} root@${ssh_target}${NC}"
  echo ""
  echo -e "${BOLD}── SSH Private Key (for Dokploy) ───────────────${NC}"
  echo ""
  cat "$SSH_PRIVATE_KEY"
  echo ""
  echo -e "${BOLD}── SSH Public Key ──────────────────────────────${NC}"
  echo ""
  cat "$SSH_PUBLIC_KEY"
  echo ""
  echo -e "${BOLD}── Key Paths ──────────────────────────────────${NC}"
  echo -e "  Private: ${SSH_PRIVATE_KEY}"
  echo -e "  Public:  ${SSH_PUBLIC_KEY}"
  echo ""
  echo -e "${BOLD}─────────────────────────────────────────────────${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ensure_deps
download_image
prompt_params
create_vm
print_summary
