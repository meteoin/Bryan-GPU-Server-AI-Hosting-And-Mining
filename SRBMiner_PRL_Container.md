# SRBMiner PRL Container

This folder contains a minimal Docker image scaffold for running Pearl mining on LuckyPool with SRBMiner.

This path is experimental only. On Bryan's tested `rigv4`, the container route built successfully but did not expose GPUs correctly, so the preferred production path is the host-native miner watcher.

## Why this image

LuckyPool's Pearl page includes an SRBMiner example using:

- `--algorithm-gpu pearlhash`
- `--wallet <PRL_ADDRESS>`
- `--worker <WORKER_NAME>`
- `--pool <REGIONAL_HOST:PORT>`

For the client's preference, this scaffold targets the US-West LuckyPool endpoint and a local Docker image name:

- pool: `pearl-us-west.luckypool.io:3360`
- image: `local/prl-srbminer:latest`

## Files

- `srbminer-prl-container/Dockerfile`
- `srbminer-prl-container/entrypoint.sh`

## Build on the host

```bash
cd ~/srbminer-prl-container
docker build -t local/prl-srbminer:latest .
```

The image sets:

- `NVIDIA_VISIBLE_DEVICES=all`
- `NVIDIA_DRIVER_CAPABILITIES=compute,utility`

This helps on hosts where `--runtime=nvidia` is required instead of `--gpus all`.

To pin a different SRBMiner version:

```bash
docker build \
  --build-arg SRBMINER_VERSION=3.6.2 \
  -t local/prl-srbminer:latest .
```

The Dockerfile should be pinned to a Pearl-capable build. `3.2.9` is too old for `pearlhash`, and the host-native validation was completed with `3.6.2`.

Avoid blindly jumping to much newer Pearl builds on these cards without checking release notes first.

## Quick miner test

```bash
docker run --rm --gpus all local/prl-srbminer:latest \
  --algorithm-gpu pearlhash \
  --wallet prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  --worker rigv4 \
  --pool pearl-us-west.luckypool.io:3360
```

If the host is configured for the NVIDIA runtime path instead of `--gpus all`, use:

```bash
sudo docker run --rm --runtime=nvidia local/prl-srbminer:latest \
  --algorithm-gpu pearlhash \
  --wallet prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  --worker rigv4 \
  --pool pearl-us-west.luckypool.io:3360
```

## Env-based test

```bash
docker run --rm --gpus all \
  -e PRL_WALLET=prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  -e PRL_WORKER=rigv4 \
  -e PRL_POOL=pearl-us-west.luckypool.io:3360 \
  local/prl-srbminer:latest
```

Quick GPU visibility check:

```bash
sudo docker run --rm --runtime=nvidia local/prl-srbminer:latest --list-devices
```

## Watcher example

```bash
python3 ~/vast_idle_mining_watcher.py \
  --machine-id 150421 \
  --image local/prl-srbminer:latest \
  --job-arg=--algorithm-gpu \
  --job-arg=pearlhash \
  --job-arg=--wallet \
  --job-arg=prl1p4pzpvqfw4czvyyy6nzgcps6q8nc350nr3736urhl0xqzdk6ekauqtxa7mk \
  --job-arg=--worker \
  --job-arg=rigv4 \
  --job-arg=--pool \
  --job-arg=pearl-us-west.luckypool.io:3360 \
  --price-gpu 0.15 \
  --min-idle-polls 2 \
  --dry-run \
  --once
```

## Notes

- Test the Docker image directly before enabling the watcher live.
- The image is local to each host, so build it on every machine that will use it.
- If you switch LuckyPool regions, update only the `--pool` value.
- If `SRBMiner-MULTI` says `Unknown algorithm 'pearlhash'`, the build is too old.
- If container GPU visibility is empty, use the host-native watcher path instead.
