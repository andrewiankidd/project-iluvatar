---
title: 📃 Overview
slug: about
description: What it's all about
draft: false
---

![Rendering of the planned cluster hardware](../../../assets/docs/about/iluvatar.jpg)
> For the love of the game
### Explanation

Project Ilúvatar is a GitOps-driven homelab framework for zero-touch, self-provisioning, bare-metal, multi-architecture Kubernetes clusters.

It automates the creation of a Raspberry Pi–based bootstrap cluster, which in turn provisions and manages a Talos-powered x86 workload cluster on the same network fabric.

Each node (ARM or x86) netboots, self-configures, and joins the correct layer automatically, with no manual intervention.

* The entire cluster can be bootstrapped from bare metal with minimal manual input.
* Git remains the single source of truth, while Argo CD continuously reconciles both infrastructure and applications.
* The bootstrap Pis host TFTP, HTTP, DNS, and Git services, enabling any new hardware to netboot and auto-configure itself.
* Talos Linux, Longhorn, and associated tooling keep the workload cluster immutable, resilient, and self-healing, with integrated storage and backup capabilities.

### Why “Project Iluvatar”?

A little Tolkien‑flavored nerdiness:

- In the Ainulindalë, Ilúvatar sings the world into being; the Ainur join the song and shape it.
- Same vibe here: this repo (Iluvatar) starts the music - it brings the first node(s) to life and lays down the platform.
- Then Ainur - the cluster and its controllers (Argo CD, Longhorn, Omni, etc.) - pick up the melody and bring the rest of the lab into existence, continuously.

It’s infrastructure as music: one theme, many parts, everything in harmony (on a few tiny computers).


## Project Goals 🎯

### Background

My <a href="https://andrewkidd.co.uk/blog/2021/04/01/Gideon-2/" target="_blank">last home server was a single machine running multiple virtual machines</a> and was handling all of this stuff great - but that when that one physical machine has an issue, it takes everything down with it, virtual or not.

Depending on how nerdy you are this impacts you on different levels. If it's just your media server sure, whatever, but if it's also all of your Personal Documents, Backups, Passwords and other important data then it's a bit more serious.

It felt fickle in that respect, and then one day the PSU failed and it just felt like work. Not being able to depend on it reliably made it pointless and now over two+ years later it still sits powered down.

### In Summary

 - I want to build a group of machines than can work as one system (cluster) 🖥️🖥️🖥️
   - Add and remove machines from the group without any configuration (scalable) 🤖
   - Run them with little maintenance (resiliency) 🔌
   - Manage everything remotely 📱
 - I want this system to be my private cloud and the brains of my house ☁️🧠🌐
   - Control my lights, cameras, etc 💡
   - Store and encrypt my personal data 🔒
   - Host my own sites, tools and services 🌐
   - Minecraft server, obviously ⛏️
