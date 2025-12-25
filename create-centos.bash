#!/usr/bin/env bash
# Download image:
# cd /var/lib/libvirt/images/
# curl -fL -O https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2 \
# 
set -euo pipefail

# --------- VM SETTINGS (edit if you want) ----------
VMNAME="cs10-vm1"
VCPUS="2"
RAM_MB="4096"
DISK_GB="40"
LIBVIRT_NET="default"   # use "default" unless you know you have a bridge
USERNAME="centos"
HOSTNAME="$VMNAME"
# ---------------------------------------------------

BASE="/var/lib/libvirt/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
IMAGEDIR="/var/lib/libvirt/images"
DISK="${IMAGEDIR}/${VMNAME}.qcow2"
SEEDDIR="${IMAGEDIR}/cloudinit-${VMNAME}"
SEEDISO="${IMAGEDIR}/seed-${VMNAME}.iso"

sudo mkdir -p "$IMAGEDIR"
sudo test -f "$BASE" || { echo "ERROR: Base image not found: $BASE"; exit 1; }

echo "[1/4] Create overlay disk for VM (base image remains template)"
# Overlay disk with explicit backing format + desired virtual size
sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" "${DISK_GB}G"

echo "[2/4] Create cloud-init seed ISO (you will be prompted for a VM password)"
sudo mkdir -p "$SEEDDIR"

# Prompt to create a SHA-512 password hash (no plaintext stored)
PASSHASH="$(openssl passwd -6)"

sudo tee "${SEEDDIR}/user-data" >/dev/null <<EOF
#cloud-config
hostname: ${HOSTNAME}
users:
  - name: ${USERNAME}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    lock_passwd: false
    passwd: ${PASSHASH}
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
EOF

sudo tee "${SEEDDIR}/meta-data" >/dev/null <<EOF
instance-id: ${VMNAME}
local-hostname: ${HOSTNAME}
EOF

# Build cidata ISO (prefers cloud-localds if present; falls back to genisoimage)
if command -v cloud-localds >/dev/null 2>&1; then
  sudo cloud-localds -v "$SEEDISO" "${SEEDDIR}/user-data" "${SEEDDIR}/meta-data"
else
  sudo genisoimage -output "$SEEDISO" -volid cidata -joliet -rock \
    "${SEEDDIR}/user-data" "${SEEDDIR}/meta-data"
fi

echo "[3/4] virt-install (FIX: --osinfo detect=on,require=off)"
sudo virt-install \
  --name "$VMNAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --import \
  --disk "path=$DISK,format=qcow2,bus=virtio" \
  --disk "path=$SEEDISO,device=cdrom" \
  --network "network=${LIBVIRT_NET},model=virtio" \
  --osinfo detect=on,require=off \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole

echo "[4/4] Done."
echo "Connect to VM console:"
echo "  sudo virsh console ${VMNAME}"
echo "Exit console with: Ctrl+]"
echo
echo "Login:"
echo "  user: ${USERNAME}"
echo "  pass: (the password you entered when prompted)"

