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
NETWORK="10.1.1"
GATEWAY="10.1.1.1"
DNS="8.8.8.8 8.8.4.4"
CIDR="/24"
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
[[ "$(id -u)" -ne 0 ]] && err "Run as root."

# ── Get next available VMID ───────────────────────────────────────────────────
get_next_vmid() {
  local id
  id=$(pvesh get /cluster/nextid)
  while [[ -f "/etc/pve/qemu-server/${id}.conf" ]] || [[ -f "/etc/pve/lxc/${id}.conf" ]]; do
    id=$((id + 1))
  done
  echo "$id"
}


show_available_ips() {
  local used_ips nmap_output
  # Store full nmap output for device identification
  nmap_output=$(nmap -sn "${NETWORK}.0/24" 2>/dev/null)

  used_ips=$(
    {
      echo "$nmap_output" | grep -oP '(\d+\.){3}\d+' | grep "^${NETWORK}\."
      for conf in /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf; do
        [[ -f "$conf" ]] || continue
        grep -oP 'ip=(\d+\.){3}\d+' "$conf" 2>/dev/null | grep -oP '(\d+\.){3}\d+' | grep "^${NETWORK}\."
      done
    } | sort -t. -k4 -n | uniq
  )

  echo ""
  echo -e "${BOLD}Used IPs on ${NETWORK}.0/24:${NC}"
  echo "$used_ips" | while read -r ip; do
    local label=""

    # Check Proxmox VMs
    for conf in /etc/pve/qemu-server/*.conf; do
      [[ -f "$conf" ]] || continue
      if grep -q "$ip" "$conf" 2>/dev/null; then
        local vmname vmid
        vmname=$(grep -oP '(?<=name: ).*' "$conf" 2>/dev/null || true)
        vmid=$(basename "$conf" .conf)
        label="VM ${vmid} (${vmname:-unknown})"
        break
      fi
    done

    # Check Proxmox CTs
    if [[ -z "$label" ]]; then
      for conf in /etc/pve/lxc/*.conf; do
        [[ -f "$conf" ]] || continue
        if grep -q "$ip" "$conf" 2>/dev/null; then
          local ctname ctid
          ctname=$(grep -oP '(?<=hostname: ).*' "$conf" 2>/dev/null || true)
          ctid=$(basename "$conf" .conf)
          label="CT ${ctid} (${ctname:-unknown})"
          break
        fi
      done
    fi

    # Check known hosts
    if [[ -z "$label" ]]; then
      [[ "$ip" == "$GATEWAY" ]] && label="Gateway"
      [[ "$ip" == "10.1.1.120" ]] && label="Proxmox Host"
    fi

    # Fall back to MAC vendor from nmap output
    if [[ -z "$label" ]]; then
      local mac_line
      mac_line=$(echo "$nmap_output" | grep -A1 "$ip" | grep "MAC Address" | sed 's/.*(\(.*\))/\1/' || true)
      label="${mac_line:-unknown device}"
    fi

    echo -e "  ${RED}${ip}${NC} → ${label}"
  done

  # Suggest free IPs
  echo ""
  echo -e "${BOLD}Suggested available IPs:${NC}"
  local count=0
  for i in $(seq 2 254); do
    local candidate="${NETWORK}.${i}"
    [[ "$candidate" == "$GATEWAY" ]] && continue
    [[ "$candidate" == "${NETWORK}.255" ]] && continue
    [[ "$candidate" == "10.1.1.120" ]] && continue
    if ! echo "$used_ips" | grep -q "^${candidate}$"; then
      echo -e "  ${GREEN}${candidate}${NC}"
      count=$((count + 1))
      [[ $count -ge 5 ]] && break
    fi
  done
  echo ""
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
  local need_update=false
  if ! command -v virt-customize &>/dev/null; then
    need_update=true
  fi
  if ! command -v nmap &>/dev/null; then
    need_update=true
  fi
  if $need_update; then
    info "Installing dependencies..."
    apt-get -qq update >/dev/null 2>&1
    apt-get -qq install -y libguestfs-tools nmap >/dev/null 2>&1
    ok "Installed dependencies"
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
  [[ ! "$CORES" =~ ^[1-9][0-9]*$ ]] && err "Invalid core count"

  # RAM
  read -rp "RAM in MB [2048]: " RAM
  RAM="${RAM:-2048}"
  [[ ! "$RAM" =~ ^[1-9][0-9]*$ ]] && err "Invalid RAM size"

  # Disk size
  read -rp "Disk size in GB [20]: " DISK_SIZE
  DISK_SIZE="${DISK_SIZE:-20}"
  [[ ! "$DISK_SIZE" =~ ^[1-9][0-9]*$ ]] && err "Invalid disk size"

  # IP selection
  show_available_ips
  read -rp "Static IP (e.g. 10.1.1.15): " STATIC_IP
  [[ -z "$STATIC_IP" ]] && err "IP is required"
  [[ ! "$STATIC_IP" =~ ^10\.1\.1\.[0-9]+$ ]] && err "IP must be in 10.1.1.0/24 range"

  # Root password (for console access fallback)
  read -rsp "Root password: " ROOT_PASS
  echo ""
  [[ -z "$ROOT_PASS" ]] && err "Password is required"

  # Confirm
  echo -e "\n${BOLD}── Summary ─────────────────────────────────────${NC}"
  echo -e "  VMID:     ${CYAN}${VMID}${NC}"
  echo -e "  Hostname: ${CYAN}${HN}${NC}"
  echo -e "  Cores:    ${CYAN}${CORES}${NC}"
  echo -e "  RAM:      ${CYAN}${RAM} MB${NC}"
  echo -e "  Disk:     ${CYAN}${DISK_SIZE} GB${NC}"
  echo -e "  IP:       ${CYAN}${STATIC_IP}${NC}"
  echo -e "  Storage:  ${CYAN}${STORAGE}${NC}"
  echo -e "${BOLD}─────────────────────────────────────────────────${NC}\n"

  read -rp "Proceed? [Y/n]: " CONFIRM
  [[ "${CONFIRM,,}" == "n" ]] && exit 0
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
  qm set "$VMID" \
    --ciuser root \
    --cipassword "$ROOT_PASS" \
    --ipconfig0 "ip=${STATIC_IP}${CIDR},gw=${GATEWAY}" \
    --nameserver "$(echo $DNS | awk '{print $1}')" \
    --searchdomain "" \
    --sshkeys "$SSH_PUBLIC_KEY" \
    --ciupgrade 0 >/dev/null

  ok "Created VM ${VMID} (${HN})"

  # Start the VM
  info "Starting VM..."
  qm start "$VMID"
  ok "VM started"

  # Wait for VM to come up
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
  [[ $retries -lt 60 ]] && ok "VM is online at ${STATIC_IP}"
}

# ── Print summary ────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  VM Created Successfully${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  SSH:  ${CYAN}ssh -i ${SSH_PRIVATE_KEY} root@${STATIC_IP}${NC}"
  echo ""
  echo -e "${BOLD}── SSH Public Key (for Dokploy) ────────────────${NC}"
  echo ""
  cat "$SSH_PUBLIC_KEY"
  echo ""
  echo -e "${BOLD}── SSH Private Key Path ────────────────────────${NC}"
  echo -e "  ${SSH_PRIVATE_KEY}"
  echo ""
  echo -e "${BOLD}─────────────────────────────────────────────────${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ensure_deps
download_image
prompt_params
create_vm
print_summary
