---
title: FAQ
slug: reference/faq
description: Short answers to the things I keep forgetting.
draft: false
---

### Where do I start?

The [Quickstart](/project-iluvatar/getting-started/quickstart/): the whole bring-up on one page. Every `.env` setting is in the [.env reference](/project-iluvatar/reference/env/).

### How do I re-bootstrap ainur?

Start the bootstrap VM, then run `bootstrap/netboot/rebootstrap.sh`. See [Re-bootstrapping Ainur](/project-iluvatar/getting-started/rebootstrap-ainur/).

### Why is one Pi still on an old build?

It boots from its SD card, which netboot flashed once and never updates. `rebootstrap.sh` wipes the card so it netboots and gets re-flashed. See [Why the SD card Pi gets left behind](/project-iluvatar/getting-started/rebootstrap-ainur/#why-the-sd-card-pi-gets-left-behind).
