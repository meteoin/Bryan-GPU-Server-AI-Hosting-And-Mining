FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG MINER_RELEASE_URL="https://github.com/Muskwak/Open-Pearl-Miner/releases/latest/download/p40-miner-linux-x64.tar.gz"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libgomp1 tar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/prl-miner

RUN curl -fsSL "${MINER_RELEASE_URL}" -o /tmp/p40-miner-linux-x64.tar.gz \
    && tar -xzf /tmp/p40-miner-linux-x64.tar.gz -C /opt/prl-miner --strip-components=1 \
    && rm -f /tmp/p40-miner-linux-x64.tar.gz \
    && chmod +x /opt/prl-miner/p40-miner

COPY entrypoint.sh /usr/local/bin/prl-miner-entrypoint
RUN chmod +x /usr/local/bin/prl-miner-entrypoint

ENTRYPOINT ["/usr/local/bin/prl-miner-entrypoint"]
CMD ["--help"]
