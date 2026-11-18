# About

This directory contains a Docker Compose project designed to run TFTP and NFS servers for the purpose of booting Raspberry Pi devices and other systems from the network.

Additionally, it includes optional 'builder' services to generate the necessary files for a desired OS on these servers.

New here? Start with the [Quickstart](https://andrewiankidd.github.io/project-iluvatar/getting-started/quickstart/).

## Components
The compose is made up of four containers with three different configurations

| Container       | raspios | ubuntuserver  | nobuild |                   ?                                                                              |
|-----------------|---------|-------------- |---------|--------------------------------------------------------------------------------------------------|
| TFTP Server     |   ✅    |       ✅     |   ✅   |   Used to host boot files for Pi                                                                  |
| NFS Server      |   ✅    |       ✅     |   ✅   |   Used to host root filesystem for Pi                                                             |
| HTTP Server     |   ✅    |       ✅     |   ✅   |   Used to host cloud-init configuration for ubuntu boots                                          |
| Debian Builder  |   ✅    |       ✅     |   ❌   |   Used to download, extract, patch and export a Debian based Pi OS image onto the server volumes  |


## Secrets

The values the clusters need that cannot be in this public repo go in `.env`; see `.env.example` and the [.env reference](https://andrewiankidd.github.io/project-iluvatar/reference/env/).

- `AINUR_*` (the Pis' password, k3s tokens, Dex and OIDC secrets): the builder writes some into user-data and serves all of them at `/secrets/ainur.env`, which ainur makes into an `ainur-secrets` Secret in each namespace that reads one.
- `ARDA_*` (Cloudflare tokens, who plays, R2 backup keys): served at `/secrets/arda.env`; ainur keeps them as its `arda-secrets` Secret, and arda gets each app's Secret from there.

Nothing to run by hand; both files are readable on the LAN while the VM runs.

## Running
**Warning: If you are using Windows, you must use a VM.**

### Running in a VM
It is recommended to use the VM, it's reproducable via the provided scripts and pre-configured with all dependencies.

You can also make use of VMs to switch between different configurations.

See [vm/README.md](vm/README.md)

#### Running natively

To run the services natively on your system, simply use Docker Compose:

```sh
sudo docker compose --profile debian-netboot up
```

### Re-bootstrapping

A Pi with an SD card boots from it once netboot has flashed it, so it keeps running the build it was flashed with. With the VM up, `./rebootstrap.sh` reboots every Pi onto the VM's latest build, wiping the SD card first on any Pi running from one. See [Re-bootstrapping Ainur](https://andrewiankidd.github.io/project-iluvatar/getting-started/rebootstrap-ainur/).

## Directory Structure

- **assets/**: Files that will be utilized during building of boot files
  - **raspios/**: Used during `pi-netboot-builder.sh`
    - Contains an RaspiOS configuration script (`apply-config.sh`) and example configuration file that is copied to the root filesystem on the NFS server.
  - **ubuntuserver/**: Used during `pi-netboot-builder.sh`
    - Contains Ubuntu cloud-config files, copied to the boot partition during image extraction
- **scripts/**: Contains scripts for building and preparing images.
  - `pi-netboot-builder.sh`: Script to download, extract, and prepare Debian based OS images for netboot.
- **vm/**: Contains scripts and configurations for setting up a virtual machine using Multipass.
  - `init/`: Initialization scripts for the VM.
    - `docker.sh`: Installs Docker and Docker Compose, and sets up the environment.
    - `mount-nfs.sh`: Mounts the NFS share to the VM to confirm it's working.
    - `mount-tftp.sh`: Mounts the TFTP share to the VM to confirm it's working.
    - `net.sh`: Configures network settings (TODO cloud-init).
  - `start.sh`: Script to start and configure the VM using Multipass.
  - `README.md`: Documentation for setting up and running the VM.
