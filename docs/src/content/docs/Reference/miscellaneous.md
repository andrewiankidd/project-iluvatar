---
title: Miscellaneous
slug: reference/miscellaneous
description: Things to do
draft: true
---

![TODO](../../../assets/todo.png)

### TODO: still a WIP


lol
```powershell
function pi0 {
    param(
        [string]$Command = 'uname -a',
        [string]$Username = 'ubuntu',
        [string]$Password = 'ubuntu',
        [string]$IPAddress = '192.168.1.50'
    )

    if ($Command -eq 'shell') {
        wsl sshpass -p $Password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$Username@$IPAddress"
    } else {
        wsl sshpass -p $Password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$Username@$IPAddress" "sudo $Command"
    }
}
function pi1 {
    param(
        [string]$Command = 'uname -a',
        [string]$Username = 'ubuntu',
        [string]$Password = 'ubuntu',
        [string]$IPAddress = '192.168.1.51'
    )

    if ($Command -eq 'shell') {
        wsl sshpass -p $Password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$Username@$IPAddress"
    } else {
        wsl sshpass -p $Password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$Username@$IPAddress" "sudo $Command"
    }
}
function pi2 {
    param(
        [string]$Command = 'uname -a',
        [string]$Username = 'ubuntu',
        [string]$Password = 'ubuntu',
        [string]$IPAddress = '192.168.1.52'
    )

    if ($Command -eq 'shell') {
        wsl sshpass -p $Password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$Username@$IPAddress"
    } else {
        wsl sshpass -p $Password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$Username@$IPAddress" "sudo $Command"
    }
}
```

```bat
PS C:\Windows\System32> pi
Warning: Permanently added '192.168.1.119' (ED25519) to the list of known hosts.
Linux valar-0 6.8.0-1031-raspi #35-Ubuntu SMP PREEMPT_DYNAMIC Thu Jul  3 15:00:20 UTC 2025 aarch64 aarch64 aarch64 GNU/Linux
```



## Reproducible Diskless K3s Bootstrap

**One-Liner**
- From bare Pi to a fully functional, offline, self-signed K3s cluster in ~10 minutes, entirely from source.

**Elevator Pitch**
- This project netboots Raspberry Pis with no local storage, installs K3s via cloud-init, and self-hosts a complete control plane: Argo CD for GitOps, Dex for OIDC, and Headlamp for cluster access. Trust is unified by a local CA distributed via cert-manager and mounted into workloads, with consistent TLS by overriding `SSL_CERT_DIR`. Everything is declarative and reproducible: `./start.sh` provisions a VM build environment, generates netboot artifacts, and reconciles the cluster to the repo state.

**Key Capabilities**
- Netbooted, diskless Raspberry Pis using NFS/TFTP + cloud-init.
- Offline-capable K3s cluster with no external dependencies beyond your CA.
- GitOps with Argo CD (Dex OIDC SSO) and Headlamp (Dex OIDC SSO).
- Consistent self-signed TLS trust via ConfigMap mount + `SSL_CERT_DIR`.
- Deterministic bootstrap using k3s HelmChart CRs and repo-driven manifests.
- Declarative OIDC client credentials for Argo via `configs.secret.extra`.

**Why It’s Notable**
- Diskless nodes and ephemeral rootfs keep hardware cheap and swappable.
- Fully self-contained (no public CA or IdP) yet secure: your CA and Dex.
- Single command to go from clean host to full cluster with identity and UI.
- Troubleshooting and reprovisioning are fast because everything is code.

**Architecture Highlights**
- Boot: cloud-init seeds K3s and manifests; systemd copies staged YAML into K3s.
- Trust: trust-manager issues a local CA; workloads mount `lab-ca` and set `SSL_CERT_DIR`.
- Identity: Dex with `staticClients`; Argo/Headlamp OIDC via Dex; Argo client secret injected under `configs.secret.extra`.
- GitOps: Argo CD deploys an app-of-apps to reconcile the cluster from this repo.
- Ingress: Traefik with cluster-local TLS from your CA.

**Suggested Doc Sections**
- Overview and Goals
- How It Works (boot flow diagram and timeline)
- Trust Model (local CA, mounts, `SSL_CERT_DIR`)
- Identity (Dex config, Argo OIDC, Headlamp OIDC, why secrets live under `configs.secret.extra`)
- Quickstart (`./start.sh`, expected artifacts, DNS records)
- Day-2 (rotate CA, rotate Dex client secret, add apps via Argo)
- Troubleshooting (Dex/Argo OIDC, TLS trust, netboot gotchas)
- Reproducibility Guarantees and Limits

**Tweet-Length**
- Diskless Pi → offline K3s with CA-backed TLS, Dex SSO, Argo GitOps, Headlamp - in minutes, from source. One command. Fully declarative.


# netboot tmpfs Disk usage

k3s base install
```bash
Warning: Permanently added '192.168.1.50' (ED25519) to the list of known hosts.
NAME       STATUS   ROLES                       AGE   VERSION        LABELS
valar-50   Ready    control-plane,etcd,master   21m   v1.33.5+k3s1   beta.kubernetes.io/arch=arm64,beta.kubernetes.io/instance-type=k3s,beta.kubernetes.io/os=linux,kidd.network/role=control-plane,kubernetes.io/arch=arm64,kubernetes.io/hostname=valar-50,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=true,node-role.kubernetes.io/etcd=true,node-role.kubernetes.io/master=true,node.kubernetes.io/instance-type=k3s
valar-51   Ready    <none>                      20m   v1.33.5+k3s1   beta.kubernetes.io/arch=arm64,beta.kubernetes.io/instance-type=k3s,beta.kubernetes.io/os=linux,kidd.network/boot=netboot,kidd.network/role=worker,kubernetes.io/arch=arm64,kubernetes.io/hostname=valar-51,kubernetes.io/os=linux,node.kubernetes.io/instance-type=k3s
valar-52   Ready    <none>                      20m   v1.33.5+k3s1   beta.kubernetes.io/arch=arm64,beta.kubernetes.io/instance-type=k3s,beta.kubernetes.io/os=linux,kidd.network/boot=netboot,kidd.network/role=worker,kubernetes.io/arch=arm64,kubernetes.io/hostname=valar-52,kubernetes.io/os=linux,node.kubernetes.io/instance-type=k3s
Warning: Permanently added '192.168.1.50' (ED25519) to the list of known hosts.
NAME                STATUS   AGE
ainur               Active   15m
ainur-cert          Active   14m
ainur-dex           Active   14m
ainur-headlamp      Active   14m
ainur-longhorn      Active   14m
ainur-sidero-omni   Active   14m
argocd              Active   16m
cert-manager        Active   21m
default             Active   21m
kube-node-lease     Active   21m
kube-public         Active   21m
kube-system         Active   21m
control plane
======
Warning: Permanently added '192.168.1.50' (ED25519) to the list of known hosts.
Filesystem                                                                 Size  Used Avail Use% Mounted on
tmpfs                                                                      1.6G   16M  1.6G   1% /run
192.168.1.66:/mnt/nfsshare/ubuntu-24.04.3-preinstalled-server-arm64+raspi  9.6G  7.1G  2.5G  75% /media/root-ro
tmpfs-root                                                                 7.8G  256M  7.6G   4% /media/root-rw
overlayroot                                                                7.8G  256M  7.6G   4% /
tmpfs                                                                      7.8G     0  7.8G   0% /dev/shm
tmpfs                                                                      5.0M     0  5.0M   0% /run/lock
tmpfs                                                                      512M     0  512M   0% /tmp
/dev/nvme0n1p1                                                             120G  2.5G  117G   3% /var/lib/longhorn/disks/nvme1
192.168.1.66:/mnt/nfsshare/home                                            9.6G  7.1G  2.5G  75% /home
tmpfs                                                                      9.4G  5.1G  4.4G  54% /var/lib/rancher/k3s
tmpfs                                                                      512M  8.4M  504M   2% /var/lib/kubelet
tmpfs                                                                      128M  2.0M  127M   2% /var/log
tmpfs                                                                      170M   12K  170M   1% /var/lib/kubelet/pods/43c8cd5e-7345-4edc-aa5c-2abb4d02ff2d/volumes/kubernetes.io~projected/kube-api-access-zq5vl
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/312bd4a9-766a-4667-9e7a-c07513eed687/volumes/kubernetes.io~projected/kube-api-access-hm7b4
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/14ae7d676801f3993f1f910912780a17fc452eb8108760b1fee06ae172d29203/shm
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/7f7e7cf634b5812ef2932222edd278dcfbc28ab3c53bf3decef2c70ae5fd4b08/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/14ae7d676801f3993f1f910912780a17fc452eb8108760b1fee06ae172d29203/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/7f7e7cf634b5812ef2932222edd278dcfbc28ab3c53bf3decef2c70ae5fd4b08/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/1f92b8d8b0121b67b265a37455b6230a26075f60a750fe4d05a8657d139e6a63/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/68d172b1dc891c029374c72ba7c05691d1ac30a2b043fa49f5b9620a1036adfa/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/dff268c6-d8cb-42cf-acd6-505a4e9d6275/volumes/kubernetes.io~projected/kube-api-access-mztnl
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/e50917da9365a7afe3ba5682eff9df7191ca81c366371634d60f8f5bc77ff2b7/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/e50917da9365a7afe3ba5682eff9df7191ca81c366371634d60f8f5bc77ff2b7/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/8273c3733ff7b0225e0c66db3aec1a58be98a09828156115de26ac732edfff9e/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/8273c3733ff7b0225e0c66db3aec1a58be98a09828156115de26ac732edfff9e/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/535d865646280d4e08246bb78e2ebdb01f3fb96d1d444357077eebd61d3b52b4/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/4404b3db76c764e470037dafcf857785fd502b4a9e06f178a6b4d30b09341302/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/6e9e9b4443a4f53ecbe943e578aaecd7f2a17c06d4a9152f5dd1dab9723b41d0/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/6e7db457-df32-4063-980e-b5c55d3b25bc/volumes/kubernetes.io~projected/kube-api-access-jl5p8
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/90f9d664-51e0-46ed-94cd-a7c14730b986/volumes/kubernetes.io~projected/kube-api-access-xblqk
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/ed9bed31c128b3088c357fb5947743a6070335b1f44b6f0ee290fcdc595247a9/shm
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/bfc3fa4a5b98537fefa86f9dc7677f9512e9d7c222a51d0e48adf31449c9822b/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/bfc3fa4a5b98537fefa86f9dc7677f9512e9d7c222a51d0e48adf31449c9822b/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/ed9bed31c128b3088c357fb5947743a6070335b1f44b6f0ee290fcdc595247a9/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/32afe6d512b3c6a4d62c671e86ccd3c855d9df23d8e7ff39af2e67a991d495b9/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/e6443c4d1ced90a6992dc6f1d883c0ca7a42c8f4aded75bcecb983f59ed34076/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/1e0f850c-68e8-4b39-85d7-0be00f7a60c8/volumes/kubernetes.io~projected/kube-api-access-dpxbp
tmpfs                                                                       16G     0   16G   0% /var/lib/kubelet/pods/ce9d9a6d-24ad-49f1-a46c-118c575fb087/volumes/kubernetes.io~secret/argocd-repo-server-tls
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/ce9d9a6d-24ad-49f1-a46c-118c575fb087/volumes/kubernetes.io~projected/kube-api-access-d8dc8
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/a22b5b2bd8be9e509b062a4b7d4e0a4b2f0a809738a344ea8101cc983d2672b2/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/a22b5b2bd8be9e509b062a4b7d4e0a4b2f0a809738a344ea8101cc983d2672b2/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/f49acc211c33c644725281e057000c45ddd3b8a0324d2e496c2650b00bfa6a2b/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/f49acc211c33c644725281e057000c45ddd3b8a0324d2e496c2650b00bfa6a2b/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/92fb372bf8226d9c291a8a30f51319ade00e619620060b1ac35122f24c6ed008/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/d88925087286346ac6dc8890eb140064736a977bf5f75d8ad2ef7ee57d021c93/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/4d7b65ef-dcf3-4991-b14a-43c330ff3985/volumes/kubernetes.io~projected/kube-api-access-vdxwh
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/b4aee720-0682-4d7e-907f-a50f91632cf2/volumes/kubernetes.io~projected/kube-api-access-xzmmn
tmpfs                                                                       16G     0   16G   0% /var/lib/kubelet/pods/73b5dcb3-750b-40ad-97aa-11f946897098/volumes/kubernetes.io~secret/longhorn-grpc-tls
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/73b5dcb3-750b-40ad-97aa-11f946897098/volumes/kubernetes.io~projected/kube-api-access-hrjvq
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/b7c6845a-51f6-443f-87e6-2bcf8cf87643/volumes/kubernetes.io~projected/kube-api-access-7lxth
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/a2007eb422b53b3db523b92b8e876a4676b036e19f794d594f38233d391fb68c/shm
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/6b401126740e07c2dc32f63ce164942c35a0e42591d128465eff7979d7baa3c5/shm
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/c85b0a9494e5ff804cadfad7f782adf87bf5e35532f1fc64fc0b01f0db5111b9/shm
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/5c5d9efe65f3d9142958bf9b11f47afbec2b7fd1e261b0bebba782dd0a91498b/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/a2007eb422b53b3db523b92b8e876a4676b036e19f794d594f38233d391fb68c/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/6b401126740e07c2dc32f63ce164942c35a0e42591d128465eff7979d7baa3c5/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/c85b0a9494e5ff804cadfad7f782adf87bf5e35532f1fc64fc0b01f0db5111b9/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/5c5d9efe65f3d9142958bf9b11f47afbec2b7fd1e261b0bebba782dd0a91498b/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/8d1fa31d221b8b5a33723d410a25855e16b6ad1937452dd27959b0faa3545a08/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/885b95805ecdc7b21918fc81d55b3a718a3917246db7574882ecab1508716c4b/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/e7a186bd36d882ddb5de4dfbb13997a2a0a3f95dbba89f141f1ee4b982b488d8/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/c98b1792a31b10eb9da9390a389c5046349835761dc4413540b88d2f563f521e/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/06c68af0773dfa2ee8d71b695bec26241a281207cf750d54e8c17c3066ffae95/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/acbc2481-9b6e-4420-85e9-61e4d03392fa/volumes/kubernetes.io~projected/kube-api-access-z259r
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/93076b4dc56a28074c4a844be403ad8e8f3d840ca35cab63096b55d605b863c2/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/93076b4dc56a28074c4a844be403ad8e8f3d840ca35cab63096b55d605b863c2/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/187d98aa35cfba1ed81c6f3d5b3650e73f6f3799cb046a1fc97157d1cae3c040/rootfs
tmpfs                                                                       16G     0   16G   0% /var/lib/kubelet/pods/6aa38e24-c80d-44e3-9ef4-886c78914e8e/volumes/kubernetes.io~secret/longhorn-grpc-tls
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/6aa38e24-c80d-44e3-9ef4-886c78914e8e/volumes/kubernetes.io~projected/kube-api-access-kgk85
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/e5dfc5b6bf52dd09086bd9e9c968ca8cc37627347da2ba5e307a0019b108065e/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/e5dfc5b6bf52dd09086bd9e9c968ca8cc37627347da2ba5e307a0019b108065e/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/f4ba50a5-0dcb-4654-8431-cf5583dbdcd9/volumes/kubernetes.io~projected/kube-api-access-jvxlt
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/be65d278-08b4-42bc-b672-bff9489ad849/volumes/kubernetes.io~projected/kube-api-access-nnn9n
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/d697fbe75e632d2a4d25b350c200cf490c6c6c90e7871804f8a63eef2e6e2a23/shm
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/e69bd89c-54c1-4c89-ae7d-6d0da8f602e3/volumes/kubernetes.io~projected/kube-api-access-dbbrv
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/b21e4629-02c7-4512-a0d1-30a0d5925793/volumes/kubernetes.io~projected/kube-api-access-nm876
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/d697fbe75e632d2a4d25b350c200cf490c6c6c90e7871804f8a63eef2e6e2a23/rootfs
tmpfs                                                                       16G   12K   16G   1% /var/lib/kubelet/pods/e77caf7f-d281-4831-86f2-9316e7b87267/volumes/kubernetes.io~projected/kube-api-access-wwh8f
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/26bbe790e960681a43485a7446d7a7cb6b4be640c7dbd949836e10adaed1bb74/shm
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/f5f227f454e433a1b6f106801511a50cce2e74c80f00e6479fc3ae3adb7647cb/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/26bbe790e960681a43485a7446d7a7cb6b4be640c7dbd949836e10adaed1bb74/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/83eab94d16261f09e06994b2046f614beb5a6c1a8bda04a6e1a063bab09a7de5/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/f5f227f454e433a1b6f106801511a50cce2e74c80f00e6479fc3ae3adb7647cb/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/83eab94d16261f09e06994b2046f614beb5a6c1a8bda04a6e1a063bab09a7de5/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/a8f9568d28f18e5ffc719c949e4b894d2840ae82d3837039eaf90550885aa171/shm
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/a8f9568d28f18e5ffc719c949e4b894d2840ae82d3837039eaf90550885aa171/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/c25e394294639596d7f59e6d10dc82208c5071ad8a309c511296321a8ba35256/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/1e2590b8bdd5f74a9c7b7ebf5f0bfb2f5aa3c82b57e5a0af6be274fe2b34af8a/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/85f14775e95c90b031ebf130fa69e07473b0d5a5ea6f1ff3a079a97c5cf701ff/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/18b7f4020e3b0d7230c1a25d98915ce246d9abb105840cd8bb791e93feaa9fad/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/fe1fe6cf735da23f037ccc8ce23b3a2ef9a39d0ee74c7d8316b8df1592e21637/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/563a2a8ad0752626f695c8360fc206ab0a6ec833671db1d89cd84dbc963a7928/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/06f031640c5c6c93a4a736d291936d9a3daed63d0ad80100a5ad443a3261b954/rootfs
fuse-overlayfs                                                             9.4G  5.1G  4.4G  54% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/541c969582791bb5f4f57f9dce2647dd6927dc4af6c8cc5f7088f20a0b53eee9/rootfs
tmpfs                                                                      1.6G   12K  1.6G   1% /run/user/1000
worker1
======
Warning: Permanently added '192.168.1.51' (ED25519) to the list of known hosts.
Filesystem                                                                 Size  Used Avail Use% Mounted on
tmpfs                                                                      794M   14M  780M   2% /run
192.168.1.66:/mnt/nfsshare/ubuntu-24.04.3-preinstalled-server-arm64+raspi  9.6G  7.1G  2.5G  75% /media/root-ro
tmpfs-root                                                                 3.9G  254M  3.7G   7% /media/root-rw
overlayroot                                                                3.9G  254M  3.7G   7% /
tmpfs                                                                      3.9G     0  3.9G   0% /dev/shm
tmpfs                                                                      5.0M     0  5.0M   0% /run/lock
tmpfs                                                                      512M     0  512M   0% /tmp
/dev/nvme0n1p1                                                             120G  2.7G  117G   3% /var/lib/longhorn/disks/nvme1
192.168.1.66:/mnt/nfsshare/home                                            9.6G  7.1G  2.5G  75% /home
tmpfs                                                                      4.7G  2.6G  2.1G  56% /var/lib/rancher/k3s
tmpfs                                                                      512M  481M   32M  94% /var/lib/kubelet
tmpfs                                                                      128M  1.6M  127M   2% /var/log
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/7c5c2f48f0496fb8a1131bf29e7c229e5166c968aa0cb7c1eff1b46cdce0e9b4/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/7c5c2f48f0496fb8a1131bf29e7c229e5166c968aa0cb7c1eff1b46cdce0e9b4/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/901afafb4cd427f3e84562dbf432105cdb2e2d647497b4e9c741fa9005ea4ebf/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/2c471b1aa6537edab1de7a0fe422b0fb2dd8fa1d0439e3b203dea3ab69ff9b9f/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/9490fd8d-44c8-4422-a1e6-f09f4d13ab74/volumes/kubernetes.io~projected/kube-api-access-2hhzf
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/0667880e-c88d-4b22-8261-d1a8c71523fd/volumes/kubernetes.io~projected/kube-api-access-q9xmw
tmpfs                                                                      7.8G     0  7.8G   0% /var/lib/kubelet/pods/9490fd8d-44c8-4422-a1e6-f09f4d13ab74/volumes/kubernetes.io~secret/argocd-repo-server-tls
tmpfs                                                                      7.8G     0  7.8G   0% /var/lib/kubelet/pods/0667880e-c88d-4b22-8261-d1a8c71523fd/volumes/kubernetes.io~secret/argocd-repo-server-tls
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/a84b2c91a7658ae0bcd3175f32490c7483c391d4cef5e9874fe2214530484ce8/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/a84b2c91a7658ae0bcd3175f32490c7483c391d4cef5e9874fe2214530484ce8/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/42d678a09bf38104d78035fcb430ce2dd5feb269fae6869830797cf0127fad4f/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/42d678a09bf38104d78035fcb430ce2dd5feb269fae6869830797cf0127fad4f/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/2185e1fb6c70261cd832f6b8b43e961efb82a183156b85f100ee0e83639a1bc9/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/8f6626e9-3d75-408e-899e-727e92b171e8/volumes/kubernetes.io~projected/kube-api-access-cqkqd
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/a854d9a80dcb1df2d388c4e609f76e60911f1b92423f8c54147ddcd2042cc73c/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/8f6626e9-3d75-408e-899e-727e92b171e8/volumes/kubernetes.io~secret/tls
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/80b55bc68f9e3ceef6a24fb92ed599e72ca459687464936a8c19e9191d890373/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/80b55bc68f9e3ceef6a24fb92ed599e72ca459687464936a8c19e9191d890373/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/25edf81ad04a8e63baeca990a86802b274f09cca74ec7b2446a5f545ac381e4a/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/db7c352e-2033-48c9-8226-0d0ec9aa3e52/volumes/kubernetes.io~projected/kube-api-access-2zz4d
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/684da1d49ce87b3a995e9bc16698a38cd81d1ad097de28d4d29c6e2afeff93cb/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/684da1d49ce87b3a995e9bc16698a38cd81d1ad097de28d4d29c6e2afeff93cb/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/9b42561f-5774-44fd-9c06-161dbdfcc687/volumes/kubernetes.io~projected/kube-api-access-mc7vx
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/b0be3ffd2a607ba3024db1ae987dd79d335b7b2b32cdcc23d0fdd7006b6be268/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/b0be3ffd2a607ba3024db1ae987dd79d335b7b2b32cdcc23d0fdd7006b6be268/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/9f457e47b29bc7702287a9e3f6d674b2d834a76805eaabb8ef12014089735803/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/981d32686f5c38eac6feba131ac634540f2bcc51806406598ee62a3d569cea29/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/44d40a9f-91b1-4ae9-a876-1423eda927cc/volumes/kubernetes.io~projected/kube-api-access-nlb2w
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/f1fb8d57-c3b3-4def-ad1d-87b7b245d1ec/volumes/kubernetes.io~projected/kube-api-access-j6gs8
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/4598374d25d515bf8714177fa0608959fc87b255ce156bf8a2965cae2506acf7/shm
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/7fcf9f2f-4c09-45d4-a6a2-d7c658144708/volumes/kubernetes.io~projected/kube-api-access-cqkgs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/4598374d25d515bf8714177fa0608959fc87b255ce156bf8a2965cae2506acf7/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/e6a4c5bb9e1c37ee306a221c3db5aef35bc0f2eeb791a18d0d85c06c2c4e8c68/shm
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/8869b939-caf6-431b-a9e1-3a2e607e2726/volumes/kubernetes.io~projected/kube-api-access-mnmnh
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/e6a4c5bb9e1c37ee306a221c3db5aef35bc0f2eeb791a18d0d85c06c2c4e8c68/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/ef75fbb1f27cdfa4923a7c19d8ef7bf502cd16ab5db313ba00710e5d25fb3d38/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/ef75fbb1f27cdfa4923a7c19d8ef7bf502cd16ab5db313ba00710e5d25fb3d38/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/4c7609f93fa828eaefc421406fcbb803d6929c2a3613a71bb1fc67584ea1e320/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/4c7609f93fa828eaefc421406fcbb803d6929c2a3613a71bb1fc67584ea1e320/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/09d02802-aca1-42b4-9a6a-4ec4be95af51/volumes/kubernetes.io~projected/kube-api-access-7j79l
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/3a061e74e8e5ca0fd69a25a2317f3be8ddc8500d947391e76593f0e255a72cd8/shm
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/3a061e74e8e5ca0fd69a25a2317f3be8ddc8500d947391e76593f0e255a72cd8/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/73fd5b11caad6582ea2ceff35bad90ed68e8ef4485a924edf4697e25e9a3a955/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/b91dc3b4664d2946242ff50e4fcb90e0254cbc3a505fbcb9731b9af5c75edd2a/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/123c471e1a0dae63264b5690239e7e754fef9473571701bafe015fb1015c8663/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/06c511d8c02d0c24fd3567e4f4409e86a4c2b2b878d825194e65025de77fbf77/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/f79373120d01b8055addaee7f27b1f6c53eae6164c92bd1a60689ca49b23a4b3/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/ea1307ec3e06b2fcfc92f7421638752f0e82fc302c0303d45a3244ef626365db/rootfs
fuse-overlayfs                                                             4.7G  2.6G  2.1G  56% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/96e7c2411d3f89313685c4df03b3d00866a87db194edfed72613d48352015f2f/rootfs
tmpfs                                                                      794M   12K  794M   1% /run/user/1000
worker2
======
Warning: Permanently added '192.168.1.52' (ED25519) to the list of known hosts.
Filesystem                                                                 Size  Used Avail Use% Mounted on
tmpfs                                                                      794M   14M  780M   2% /run
192.168.1.66:/mnt/nfsshare/ubuntu-24.04.3-preinstalled-server-arm64+raspi  9.6G  7.1G  2.5G  75% /media/root-ro
tmpfs-root                                                                 3.9G  253M  3.7G   7% /media/root-rw
overlayroot                                                                3.9G  253M  3.7G   7% /
tmpfs                                                                      3.9G     0  3.9G   0% /dev/shm
tmpfs                                                                      5.0M     0  5.0M   0% /run/lock
tmpfs                                                                      512M     0  512M   0% /tmp
/dev/nvme0n1p1                                                             120G  2.4G  117G   2% /var/lib/longhorn/disks/nvme1
192.168.1.66:/mnt/nfsshare/home                                            9.6G  7.1G  2.5G  75% /home
tmpfs                                                                      4.7G  3.2G  1.5G  69% /var/lib/rancher/k3s
tmpfs                                                                      512M  112K  512M   1% /var/lib/kubelet
tmpfs                                                                      128M  440K  128M   1% /var/log
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/a89f8115263ddcae5280a8ba9a8431a7360783bce1d85d7cc52d176b3a81cbe5/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/a89f8115263ddcae5280a8ba9a8431a7360783bce1d85d7cc52d176b3a81cbe5/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/670fa0e276f44b9be6f75a747348c32611c4bc06a7edf9880c6acbd34faf69ac/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/0664fade8b69e0c2fb29816feb04a9f76a834a288a35382f30320ef384042286/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/e467f4f0-6b32-48b7-ac12-eeda51674dc7/volumes/kubernetes.io~projected/kube-api-access-2xcl9
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/fa4964b1ddb523a938c866d1dc63c39d192ab43318c24d5dd051ae65c8c26caa/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/fa4964b1ddb523a938c866d1dc63c39d192ab43318c24d5dd051ae65c8c26caa/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/255059805d8b4422c4be5a3a9442217d17406db0559db5cc4bcf685b0d673916/rootfs
tmpfs                                                                      7.8G     0  7.8G   0% /var/lib/kubelet/pods/9986e336-f833-4a55-bc59-2bfe62eeef65/volumes/kubernetes.io~secret/argocd-repo-server-tls
tmpfs                                                                      7.8G     0  7.8G   0% /var/lib/kubelet/pods/9986e336-f833-4a55-bc59-2bfe62eeef65/volumes/kubernetes.io~secret/argocd-dex-server-tls
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/9986e336-f833-4a55-bc59-2bfe62eeef65/volumes/kubernetes.io~projected/kube-api-access-wzdbs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/f67b0a4db5a13dbf0366c1c618fa3c038096fdba0345984d0ba14e17d1d0c28c/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/f67b0a4db5a13dbf0366c1c618fa3c038096fdba0345984d0ba14e17d1d0c28c/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/4b350f741cade6d9f8befd55435b98252cf902bd8bf6b5ffa64f7453a5671ac2/rootfs
tmpfs                                                                       64M   12K   64M   1% /var/lib/kubelet/pods/d4c2496f-a3a5-4db2-a757-02743d52348b/volumes/kubernetes.io~projected/kube-api-access-dljhd
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/bd9cbeac3d2fd331e23a440b726b9499694f32408db53f84426fdfd919b5c4b1/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/bd9cbeac3d2fd331e23a440b726b9499694f32408db53f84426fdfd919b5c4b1/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/9a9f6f19-d0ad-44dd-a7f2-f3a672658ec4/volumes/kubernetes.io~projected/kube-api-access-87pfj
tmpfs                                                                      7.8G  4.0K  7.8G   1% /var/lib/kubelet/pods/9a9f6f19-d0ad-44dd-a7f2-f3a672658ec4/volumes/kubernetes.io~secret/config
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/5f0af5b8f02aa5f4000f3680af1446bf54369b90cfe3890ee5808916c9397b53/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/5f0af5b8f02aa5f4000f3680af1446bf54369b90cfe3890ee5808916c9397b53/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/f2a48242-11d7-4596-9e34-c5fa7ae47836/volumes/kubernetes.io~projected/kube-api-access-pmlbl
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/36ea96e0a3e2c8b4aad5ba2a54f48f36201f76d1b77f2988ae16abe3e9536e63/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/36ea96e0a3e2c8b4aad5ba2a54f48f36201f76d1b77f2988ae16abe3e9536e63/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/2e414e69887648685db51780144da20588c6571e93b2c976ac4db76df31e0385/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/b04bb005a9d6f5cb89152ec20033c88c7572bf2936b558eebfd8a58b2f08f7f5/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/60e5b3d00a1fff4462586d85909a1abeb272b1d113a9dee6b3d497acc0a7b556/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/b8128a8a-3aaa-485b-b2ae-7b685e20294e/volumes/kubernetes.io~projected/kube-api-access-vcm58
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/f62602e38425fe41c380aaa926cc2f6b400fd7f16792b76b8b91358e7aba982a/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/f62602e38425fe41c380aaa926cc2f6b400fd7f16792b76b8b91358e7aba982a/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/481088bed76083029875d87d60781124591ead60f1c1d94ca6cc0a5f997481d1/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/36482633-3151-4179-9684-1fa88135fdd7/volumes/kubernetes.io~projected/kube-api-access-sr65z
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/6296af40-ba7c-4d51-9ce4-07fcefb49cd8/volumes/kubernetes.io~projected/kube-api-access-76qjv
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/0fb04314b9783441a3032a009670c44f66df06f3208543e516ed3cd06fda6394/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/0fb04314b9783441a3032a009670c44f66df06f3208543e516ed3cd06fda6394/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/8aeff4483713f4fa0ef62743f15d4facf2ff4247fa0bd55b2ebd4e78dd9a8fdc/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/8aeff4483713f4fa0ef62743f15d4facf2ff4247fa0bd55b2ebd4e78dd9a8fdc/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/d051a9d3-ae4c-46e6-b928-967a7998f5f5/volumes/kubernetes.io~projected/kube-api-access-jv2k6
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/4fd423d8-b27c-45f7-9260-be520ee1323e/volumes/kubernetes.io~projected/kube-api-access-kr7jn
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/7d6edd7beaeaf33d96274b7e378e8af5945e81bac9f306cb9f976941e4eff165/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/7d6edd7beaeaf33d96274b7e378e8af5945e81bac9f306cb9f976941e4eff165/rootfs
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/67f5b74892a5b11e17b4bb297265ed22a3b849083d6185b12d05261603d1de1a/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/67f5b74892a5b11e17b4bb297265ed22a3b849083d6185b12d05261603d1de1a/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/ce38412d-462a-452a-994c-6bdbadf3372f/volumes/kubernetes.io~projected/kube-api-access-lck9p
shm                                                                         64M     0   64M   0% /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/abf802621f6623b385d64696e28a776faa7c50c9019c15a501c5a18cf5c1af01/shm
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/abf802621f6623b385d64696e28a776faa7c50c9019c15a501c5a18cf5c1af01/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/e2e14158538dc75215f650351ee8708787d490095da52cdbc7b3e6ec230b2354/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/f073cf58c8f9ed28bd74ae90c972eba68fe1fbec4245ad5d296567144e23b70b/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/c18952c50bcc397ed0eec99bc8ce0593f4a60acb5018bdc20e56f95ccaaff2d7/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/99c5430fdc91f6679270a69eb6d3c210ded736da413e3c1041c6e60dc76fa344/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/9e8155efba8ee940100a09f2430b8de5f984b64863034104fe383d6c82107cc8/rootfs
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/d5f1dca402b97faa5ef01d68662a2adb4fe2690b0230ebf12bc4d3a215ffc29a/rootfs
tmpfs                                                                      7.8G   12K  7.8G   1% /var/lib/kubelet/pods/62fcd607-2f8f-4986-9c0e-d037500d4f08/volumes/kubernetes.io~projected/kube-api-access-czm8l
fuse-overlayfs                                                             4.7G  3.2G  1.5G  69% /run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io/b803d8357603557bc0ddf66add695d90f921c4593679cec1009cf23aa41afda9/rootfs
tmpfs                                                                      794M   12K  794M   1% /run/user/1000
PS C:\Users\Andrew>
```
