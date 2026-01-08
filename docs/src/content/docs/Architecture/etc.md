---
title: 🧰 Misc
slug: architecture/etc/hardware
description: Aux infrastructure that keeps the lab online
sidebar:
  order: 4
draft: false
---

These are mostly optional extras

### Network
![Image of Dream Machine SE](../../../assets/docs/about/router.png)
A Ubiquiti Dream Machine SE acts as my primary router (among other things). It runs the network and provides a single pane of glass for all settings and monitoring.

### Power Management (PoE)
![Image of USW-Pro-24-PoE](../../../assets/docs/about/switch.png)
![Port map of USW-Pro-24-PoE](../../../assets/docs/about/ports.png)
I have a Ubiquiti USW-Pro-24-PoE network switch; which provides 400W of Power-over-Ethernet across 24 Ports.
Using this switch I can remotely control the power to nodes (and other devices) on demand.

### Remote Management
![Image of JetVM](../../../assets/docs/about/jetkvm.png)

I use a JetKVM for remotely controlling nodes. This was a huge help in diagnosing issues during the development of this project.

JetKVMs also offers extra features like the ability to mount images (IMG, ISO, etc) directly to connected devices, this would have been amazing for flashing the netboot enabler image, but didn't seem to work when I tried it.
