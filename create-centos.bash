#!/usr/bin/env bash
# Download image (run once):
# cd /var/lib/libvirt/images/
# curl -fL -O https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2

set -euo pipefail

# Usage: ./virt-install-fixed <vmname>
VMNAME="${1:-}"
if [[ -z "$VMNAME" ]]; then
  echo "Usage: $0 <vmname>"
  exit 1
fi

# ---------------- VM SETTINGS ----------------
VCPUS="2"
RAM_MB="4096"
DISK_GB="40"
BRIDGE_IF="br0"
USERNAME="centos"
HOSTNAME="$VMNAME"

# Prompt for centos password BEFORE build (like your older versions)
read -r -s -p "Enter password for '${USERNAME}' on VM '${VMNAME}': " USER_PASS
echo
read -r -s -p "Confirm password: " USER_PASS2
echo
if [[ -z "$USER_PASS" || "$USER_PASS" != "$USER_PASS2" ]]; then
  echo "ERROR: Password empty or mismatch."
  exit 1
fi
# --------------------------------------------

IMAGEDIR="/var/lib/libvirt/images"
BASE="${IMAGEDIR}/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
DISK="${IMAGEDIR}/${VMNAME}.qcow2"
SEEDDIR="${IMAGEDIR}/cloudinit-${VMNAME}"
SEEDISO="${IMAGEDIR}/seed-${VMNAME}.iso"

sudo mkdir -p "$IMAGEDIR"

# ---- Pre-flight checks ----
if [[ ! -f "$BASE" ]]; then
  echo "ERROR: Base image not found: $BASE"
  echo "Download it first:"
  echo "  sudo curl -fL -o $BASE https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
  exit 1
fi

if ! ip link show "$BRIDGE_IF" &>/dev/null; then
  echo "ERROR: Bridge '$BRIDGE_IF' not found on host."
  exit 1
fi

# ---- Clean rebuild if VM exists ----
if virsh dominfo "$VMNAME" &>/dev/null; then
  echo "Removing existing VM '$VMNAME'..."
  sudo virsh destroy "$VMNAME" &>/dev/null || true
  sudo virsh undefine "$VMNAME" --remove-all-storage &>/dev/null || true
fi

# Cleanup old artifacts
sudo rm -f "$DISK" "$SEEDISO"
sudo rm -rf "$SEEDDIR"
sudo mkdir -p "$SEEDDIR"

# ---- Create VM disk (backing on BASE) ----
sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" "${DISK_GB}G" >/dev/null

# ---- Cloud-init: password SSH + install/start qemu-guest-agent ----
sudo tee "${SEEDDIR}/user-data" >/dev/null <<EOF
#cloud-config
hostname: ${HOSTNAME}

users:
  - name: ${USERNAME}
    groups: wheel
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false

chpasswd:
  expire: false
  list: |
    ${USERNAME}:${USER_PASS}

ssh_pwauth: true
disable_root: true

write_files:
  - path: /etc/ssh/sshd_config.d/99-centos-password.conf
    owner: root:root
    permissions: '0644'
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      UsePAM yes
      PermitRootLogin no

# Install + enable qemu-guest-agent so virsh can query IP by default
packages:
  - qemu-guest-agent

runcmd:
  - [ sh, -c, "restorecon -Rv /etc/ssh/sshd_config.d || true" ]
  - [ sh, -c, "systemctl enable --now sshd || true" ]
  - [ sh, -c, "systemctl restart sshd || true" ]
  - [ sh, -c, "systemctl enable --now qemu-guest-agent || true" ]
  - [ sh, -c, "systemctl restart qemu-guest-agent || true" ]
EOF

sudo tee "${SEEDDIR}/meta-data" >/dev/null <<EOF
instance-id: ${VMNAME}
local-hostname: ${HOSTNAME}
EOF

sudo genisoimage -output "$SEEDISO" -volid cidata -joliet -rock \
  "${SEEDDIR}/user-data" "${SEEDDIR}/meta-data" >/dev/null

# ---- Create + boot VM on LAN bridge ----
# Force-add guest agent channel so the agent always has /dev/virtio-ports/org.qemu.guest_agent.0
sudo virt-install \
  --name "$VMNAME" \
  --vcpus "$VCPUS" \
  --memory "$RAM_MB" \
  --disk path="$DISK",format=qcow2,bus=virtio \
  --disk path="$SEEDISO",device=cdrom \
  --os-variant centos-stream10 \
  --network bridge="$BRIDGE_IF",model=virtio \
  --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole

echo
echo "VM '$VMNAME' created."

# ---- IP helper: domifaddr first, then guest agent (most reliable) ----
get_ip() {
  local name="$1"
  local ip=""

  # Try domifaddr
  ip="$(virsh domifaddr "$name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1 || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  # Try qemu guest agent
  ip="$(virsh qemu-agent-command "$name" '{"execute":"guest-network-get-interfaces"}' --timeout 10 2>/dev/null \
    | grep -oE '"ip-address":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
    | cut -d: -f2 | tr -d '"' \
    | grep -v '^127\.' \
    | head -n1 || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return 0
  fi

  return 1
}

echo "Waiting for VM to report IP via guest agent..."
for _ in {1..30}; do
  if ip="$(get_ip "$VMNAME")"; then
    echo "IP: $ip"
    echo "SSH (will prompt for password):"
    echo "  ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ${USERNAME}@${ip}"
    exit 0
  fi
  sleep 2
done

echo "Could not determine IP yet."
echo "Try:"
echo "  virsh qemu-agent-command $VMNAME '{\"execute\":\"guest-network-get-interfaces\"}' --timeout 10"
echo "  (or check your router DHCP leases)"
exit 0

