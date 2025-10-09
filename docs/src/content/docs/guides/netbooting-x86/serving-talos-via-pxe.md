---
title: Serving Talos via PXE
description: Delivering immutable nodes on demand
---

Once DHCP and firmware are cooperating, Talos just needs three files and a machine configuration to come alive. This page shows how those pieces are assembled inside the bootstrap stack.

## Explanation

Talos publishes a boot artefact bundle for every release:

- `metal-amd64.iso` (not used here, but handy for recovery)
- `metal-amd64.raw.xz` (squashfs root image we serve over HTTP)
- `vmlinuz-amd64` (kernel)
- `initramfs-amd64.xz`

We place the kernel/initramfs in TFTP for quick access and leave the heavier root image on HTTP. The iPXE script then loads the kernel, injects kernel parameters pointing at the Talos machine config endpoint, and hands off.

## Implementation

### 1. Download and publish Talos artefacts

From your workstation (or using the bootstrap automation pipeline):

```bash
export TALOS_VERSION=v1.7.3
cd bootstrap/netboot

# download the release artefacts
curl -LO https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.raw.xz
curl -LO https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/vmlinuz-amd64
curl -LO https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/initramfs-amd64.xz

# copy into the served volumes
install -m 0644 vmlinuz-amd64 boot/talos/vmlinuz-amd64
install -m 0644 initramfs-amd64.xz boot/talos/initramfs-amd64.xz
install -m 0644 metal-amd64.raw.xz os/talos/${TALOS_VERSION}/metal-amd64.raw.xz

# grab fresh iPXE binaries if you need them
curl -Lo boot/talos/undionly.kpxe https://boot.ipxe.org/undionly.kpxe
curl -Lo boot/talos/ipxe.efi https://boot.ipxe.org/ipxe.efi
```

The docker-compose stack exposes `boot/` via TFTP and `os/` via HTTP (`http://192.168.0.66:8080/` by default).

### 2. Generate machine configs

Talos machine configs are immutable YAML blobs. Generate them once, commit to Git, and expose over HTTPS (the bootstrap Pis run an `nginx` Deployment for this exact purpose).

```bash
talosctl gen config iluvatar \
  https://192.168.0.66:6443 \
  --with-secrets \
  --output docs/src/content/assets/talos \
  --with-docs=false \
  --install-disk /dev/nvme0n1
```

This produces `controlplane.yaml`, `worker.yaml`, and `talosconfig`. Commit them to the repository and have the bootstrap cluster serve them from, e.g., `https://bootstrap.iluvatar.lan/talos/controlplane.yaml`.

### 3. Write the iPXE script

Create `boot/talos/talos.ipxe`:

```ipxe
#!ipxe

set boot-url http://192.168.0.66:8080/talos
kernel ${boot-url}/vmlinuz-amd64 initrd=initramfs-amd64.xz \
  console=tty0 console=ttyS0,115200 \
  talos.platform=metal \
  talos.config=${boot-url}/machine-config/${mac:hexhyp}
initrd ${boot-url}/initramfs-amd64.xz
boot ||
prompt --key 0x197e --timeout 2000 --label retry Boot failed, retrying...
goto start
```

The `${mac:hexhyp}` trick lets each node request `machine-config/aa-bb-cc-dd-ee-ff`. Symlink or copy the appropriate control-plane/worker YAML into that directory to assign roles.

Point dnsmasq at the script by adjusting the boot entry:

```ini
dhcp-boot=tag:efi,talos/ipxe.efi
dhcp-boot=tag:!efi,talos/undionly.kpxe
dhcp-option=option-209,http://192.168.0.66:8080/talos/talos.ipxe
```

With Option 209 in place, any iPXE binary that chainloads from firmware will immediately pull `talos.ipxe` over HTTP.

### 4. Tell Talos where to find the control plane

If you are doing an initial bootstrap, use:

```bash
talosctl --talosconfig talosconfig bootstrap
```

from a laptop once the first control-plane node is up. After that, Talos automatically points new workers at the Kubernetes API server defined inside the machine config.

### 5. Automate with GitOps

Store the Talos artefact version, iPXE script, and machine mappings in Git. Argo CD (running on the bootstrap Pis) syncs the ConfigMaps and hostPath volumes so any change—new Talos release, machine promoted to control plane, etc.—propagates automatically.

## Troubleshooting

- **Stuck at PXE prompt?** Double-check dnsmasq logs; the firmware may be requesting IPv6 or the wrong architecture tag.
- **Talos kernel boots but reboots instantly?** Verify the machine config URL resolves from inside the bootstrap VLAN and that the TLS certificate matches the hostname you embedded.
- **Workers never join Kubernetes?** Make sure your control-plane machine configs use `type: controlplane` and that `talosctl gen config` was run with the correct API endpoint.

## Next Steps

With Talos nodes netbooting reliably, continue with [PXE Boot & Talos Install](/project-iluvatar/getting-started/bootstrap-arda/pxe-boot-talos/) for the high-level cluster bring-up, or move straight to [Deploy Core Workloads](/project-iluvatar/getting-started/deploy-core-workloads/).
