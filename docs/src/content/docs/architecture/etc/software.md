---
title: Supporting Software
description: Helper tooling around the core clusters
draft: true
---

## Other Tools
Some useful bits

### Bootstrap Script
To aid in the process of setting up the bootstrap cluster, I repurposed some scripts I had from [when I first experimented with Pi Netboot using RaspiOS](/project-iluvatar/guides/netboot/).

This scripts downloads the SD Card image, extract it and patch the boot files to configure them for booting over the network.

### Bootstrap Docker Compose
And since most people probably dont have a TFTP/NFS server sitting around, I put together a docker-compose file that can spin these servers up, and optionally run the bootstrap script in a container too.

###  Bootstrap Multipass VM
Lastly, since Windows doesn't support host mode networking in Docker, we cheat and wrap it in a reproducable Linux VM. Specifically an Ubuntu Multipass VM, scripted with a combination of bash and cloud-init
