FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG SRBMINER_VERSION="3.3.2"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libgomp1 tar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/srbminer

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN srbminer_version_dashed="$(printf '%s' "${SRBMINER_VERSION}" | tr '.' '-')" \
    && srbminer_release_url="https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRBMINER_VERSION}/SRBMiner-Multi-${srbminer_version_dashed}-Linux.tar.gz" \
    && curl -fsSL "${srbminer_release_url}" -o /tmp/srbminer-linux.tar.gz \
    && mkdir -p /tmp/srbminer-extract \
    && tar -xzf /tmp/srbminer-linux.tar.gz -C /tmp/srbminer-extract \
    && find /tmp/srbminer-extract -type f -name 'SRBMiner-MULTI' -exec cp {} /opt/srbminer/SRBMiner-MULTI \; \
    && rm -rf /tmp/srbminer-linux.tar.gz /tmp/srbminer-extract \
    && chmod +x /opt/srbminer/SRBMiner-MULTI

COPY entrypoint.sh /usr/local/bin/prl-srbminer-entrypoint
RUN chmod +x /usr/local/bin/prl-srbminer-entrypoint

ENTRYPOINT ["/usr/local/bin/prl-srbminer-entrypoint"]
CMD ["--help"]
