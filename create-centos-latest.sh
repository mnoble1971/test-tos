#!/usr/bin/env bash

# cd /var/lib/libvirt/images/
# curl -fL -O https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2


set -euo pipefail

# Usage: ./virt-install8 <vmname>
VMNAME="${1:-}"
if [[ -z "$VMNAME" ]]; then
  echo "Usage: $0 <vmname>"
  exit 1
fi

# ---------------- VM SETTINGS ----------------
VCPUS="2"
RAM_MB="4096"
DISK_GB="40"

BRIDGE_IF="br0"          # LAN bridge on the KVM host
USERNAME="centos"
HOSTNAME="$VMNAME"
# --------------------------------------------

IMAGEDIR="/var/lib/libvirt/images"
BASE="${IMAGEDIR}/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
DISK="${IMAGEDIR}/${VMNAME}.qcow2"
SEEDDIR="${IMAGEDIR}/cloudinit-${VMNAME}"
SEEDISO="${IMAGEDIR}/seed-${VMNAME}.iso"

# ---- Read centos password interactively (BEFORE build) ----
read -r -s -p "Enter password for '${USERNAME}' on VM '${VMNAME}': " USER_PASS
echo
read -r -s -p "Confirm password: " USER_PASS2
echo
if [[ "$USER_PASS" != "$USER_PASS2" ]]; then
  echo "ERROR: Passwords do not match."
  exit 1
fi
if [[ -z "$USER_PASS" ]]; then
  echo "ERROR: Password cannot be empty."
  exit 1
fi

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
  echo "Create br0 and enslave your physical NIC first."
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

# ---- Cloud-init: enable password login for centos ----
# (No SSH keys; password only.)
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

runcmd:
  - [ sh, -c, "restorecon -Rv /etc/ssh/sshd_config.d || true" ]
  - [ sh, -c, "systemctl enable --now sshd || true" ]
  - [ sh, -c, "systemctl restart sshd || true" ]
EOF

sudo tee "${SEEDDIR}/meta-data" >/dev/null <<EOF
instance-id: ${VMNAME}
local-hostname: ${HOSTNAME}
EOF

# ---- Create cloud-init ISO ----
sudo genisoimage -output "$SEEDISO" -volid cidata -joliet -rock \
  "${SEEDDIR}/user-data" "${SEEDDIR}/meta-data" >/dev/null

# ---- Create + boot VM on LAN bridge ----
sudo virt-install \
  --name "$VMNAME" \
  --vcpus "$VCPUS" \
  --memory "$RAM_MB" \
  --disk path="$DISK",format=qcow2,bus=virtio \
  --disk path="$SEEDISO",device=cdrom \
  --os-variant centos-stream10 \
  --network bridge="$BRIDGE_IF",model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole

echo
echo "VM '$VMNAME' created on LAN bridge '${BRIDGE_IF}'."
echo "centos password auth enabled."
echo
echo "Get IP:"
echo "  virsh domifaddr $VMNAME"
echo
echo "SSH (password prompt):"
echo "  ssh ${USERNAME}@<vm-ip>"
echo
echo "If your PC tries keys first, force password prompt:"
echo "  ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ${USERNAME}@<vm-ip>"

