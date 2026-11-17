---
title: FAQ
slug: reference/faq
description: Short answers to the things I keep forgetting.
draft: false
---

### How do I re-bootstrap ainur?

Start the bootstrap VM, then run `bootstrap/netboot/rebootstrap.sh`. See [Re-bootstrapping Ainur](/project-iluvatar/getting-started/rebootstrap-ainur/).

### Why is one Pi still on an old build?

It boots from its SD card, which netboot flashed once and never updates. `rebootstrap.sh` wipes the card so it netboots and gets re-flashed. See [Why the SD card Pi gets left behind](/project-iluvatar/getting-started/rebootstrap-ainur/#why-the-sd-card-pi-gets-left-behind).
