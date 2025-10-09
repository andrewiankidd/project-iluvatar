---
title: Multiple Nodes
description: double vision
draft: true
---

![Rendering of the planned cluster hardware](../../../../assets/todo.png)

### TODO: still a WIP



### Creating Netboot server on Master Node

Progress feels good so far.

We can now take an Raspberry Pi with a blank SD card, plug it in to our network and without any further interaction it will turn itself into a fully configured and active NixOS install.

But we're **still** relying on the bootstrap VM for most of this process, we need to give master nodes the ability to fill this gap.

In order to do this I'm going to update my custom `sd/default.nix` configuration files, this time defining a kubernetes workload that reproduces our bootstrap server (NFS, TFTP and OS generation).

```
  services = {
    k3s = {
      enable = true;
      role = "agent";
      token = "todo-project-iluvatar";
      serverAddr = "https://192.168.0.66:6443";
      extraFlags = toString [
        "--debug"
      ];
    };
  }

  networking = {
    hostName = "project-iluvatar-sd-${builtins.substring 0 10 (builtins.hashString "sha256" "project-iluvatar")}";
    firewall = {
      allowedTCPPorts = [
        # SSH
        22

        # Kubernetes API Server
        6443

        # NFSv3
        111
        2049
        32765-32768
      ];
      allowedUDPPorts = [
        # TFTP
        69

        # NFSv3
        111
        2049
        32765-32768
      ];
    };
  };
```

### IP Reconciliation
TODO
Nodes with SD cards should scan the network (arp? kubctl?) and detect if TFTP_IP/Option 66/192.168.0.66 exists
If the master node can not be found, then the SD card node tries to take the TFTP_IP for itself and become the new master
