---
title: 'Summary & Next Steps'
slug: guides/netbooting-raspberry-pi/summary
description: Because otherwise I'll forget
sidebar:
  order: 8
draft: false
---

Over this guide I have learned the process of
 - Setting up TFTP and NFS Servers
 - How PXE and Netboot works, and their differences
 - Using Cloud-Init to pre-configure Ubuntu machines
 - Utilizing OverlayFS to run multiple machines from the same base filesystem

This is the first real milestone in my project and shows that what I am trying to achieve with it is not out of reach.


### Automation

The process described in this guide is mostly for reference, I am lazy and do not like doing the same thing over and over again, so I have scripted this entire process as part a reproducible Ubuntu VM, utilizing bash scripts and docker images I've put together to source control the process.

[More info on the automation](../../Architecture/bootstrap-vm.md)

### End to End Video
![TODO](../../../../assets/todo.png)

TODO it would probably be nice to have a video here from VM/start.sh > to a ready Pi console.

## Next Steps

I am glad to have this working, but there is still much to be done to complete the larger project, primarily adding Kubernetes into the mix and reproducing everything we've done here inside the resulting cluster.
