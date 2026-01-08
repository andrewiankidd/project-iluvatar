# pi-netboot-builder.dockerfile
# syntax=docker/dockerfile:1.5
ARG YQ_VERSION=4.44.3
FROM ubuntu:22.04

ARG YQ_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y wget unzip xz-utils zstd tar rsync ca-certificates \
    util-linux kmod nfs-common mount zip gzip coreutils findutils \
 && update-ca-certificates \
 && ARCH=$(dpkg --print-architecture) \
 && case "${ARCH}" in \
      amd64) YQ_ARCH=amd64 ;; \
      arm64|aarch64) YQ_ARCH=arm64 ;; \
      *) echo "unsupported architecture: ${ARCH}"; exit 1 ;; \
    esac \
 && wget -q "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${YQ_ARCH}" -O /usr/bin/yq \
 && chmod +x /usr/bin/yq

RUN mkdir -p /mnt/netboot/scripts

WORKDIR /mnt/netboot

COPY ./scripts/pi-netboot-builder.sh /mnt/netboot/scripts/pi-netboot-builder.sh
RUN chmod +x /mnt/netboot/scripts/pi-netboot-builder.sh

CMD ["bash", "/mnt/netboot/scripts/pi-netboot-builder.sh"]
