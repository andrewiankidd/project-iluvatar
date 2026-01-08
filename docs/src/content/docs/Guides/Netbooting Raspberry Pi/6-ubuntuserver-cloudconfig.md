---
title: 'Ubuntu Server and Cloud-Init'
slug: guides/netbooting-raspberry-pi/ubuntuserver-cloudconfig
description: branding bare metal
sidebar:
  order: 6
draft: false
---

This guide covers how to make use of [Ubuntu Server for Raspberry Pi](https://ubuntu.com/tutorials/how-to-install-ubuntu-on-your-raspberry-pi#1-overview) and [cloud-init](https://cloudinit.readthedocs.io) to reliably pre-configure Raspberry Pi's that are booted over the network.

## Explanation

RaspiOS got me through the first experiments, but I wanted something more standard and reliable than my hacky config script.

The first approach I took on this was NixOS, but I failed spectacularly due to lack of official support and maybe moreso my lack of experience with Nix and it's tooling.

So I parked this project and was stuck for several months at this phase deciding on what to do next - then I realized, I'm using cloud-init to create the VM I use to host all of this development work, can't I use cloud-init here too?

### Components

#### Cloud Init
[cloud-init](https://cloud-init.io/) is Canonical’s declarative bootstrap system, it processes user provided configuration on first boot and handles:
- Creating users, SSH keys, packages, and services
- Applying static network config or DHCP settings
- Running arbitrary shell commands during provisioning

It's an industry standard tool used for initializing Linux distributions in cloud environments and can be utilized on bare metal too - unfortunately isn't supported by RaspiOS.

#### Ubuntu Server (for Pi)

Thankfully, Ubuntu Server offers both official images for the Pi as well as first-class cloud-init support, so it ticks the boxes and we'll be using that as a base OS now.

## Implementation

Assuming you follow the process previously outlined, but instead using a Ubuntu Server image instead of a RaspiOS one, you should find yourself at a shell prompt but with no way to log in, as no users are configured yet.

<TODO SCREENSHOT>

To bet these, we will make the following changes to our process

**Enable Cloud-Init in cmdline.txt**

We'll update our TFTP hosted `cmdline.txt` file to include the following flags, indicating the datasource is 'nocloud' and the source is our netboot server IP
> ds=nocloud;s=http://192.168.1.66/

Now cloud-init knows where to look, we need to give it something to retrieve

**Define Configuration in TFTP Server**

Cloud-Init will look for the config in the specified source, which should be served over HTTP on the IP defined in `cmdline.txt`

We can get this server easily by updating our existing `docker-compose.yml` to include:
```yaml
# docker-compose.yml
  # HTTP server for cloud-init metadata (user-data, meta-data)
  bootstrap-http:
    image: nginx:alpine
    container_name: bootstrap-http
    profiles:
      - netboot
      - debian-netboot
    env_file:
      - .env
    volumes:
      - netboot-boot-data:/usr/share/nginx/html:ro
    ports:
      - "80:80"
    restart: unless-stopped
```

Define a `user-data` file in the root of the boot filesystem alongside `cmdline.txt`, with contents like so:
```yaml
# user-data
#cloud-config
# https://cloudinit.readthedocs.io/

hostname: valar-0

resize_rootfs: false

ssh_pwauth: true

package_update: true

package_upgrade: false

users:
  - name: ubuntu
    plain_text_passwd: ubuntu
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo,adm

chpasswd:
  expire: false

final_message: "Cloud-init complete."

```


### Review

<video controls width="100%" title="First Boot">
    <source src="/project-iluvatar/assets/docs/guides/bootstrap/prep/ubuntu-boot.mp4" type="video/mp4">
    Your browser does not support the video tag.
</video>

![capture of Ubuntu shell](../../../../assets/docs/guides/bootstrap/prep/ubuntu.png)

It boots and we can login! 🥳🚀

So now we are able to boot Rapsberry Pis into a working install of Ubuntu Server, and with cloud-init we can define custom users, packages, scripts - pretty much anything we want.

## Next Steps
If you are planning on running a single system this way, great! But what if you want to run multiple machines? Having multiple running instances of the same OS try and use the same root filesystem can only end badly.

So next I will attempt to solve this.
