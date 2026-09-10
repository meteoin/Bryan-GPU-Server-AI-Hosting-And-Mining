# PRL Mining Container

This folder contains a minimal Docker image scaffold for using the Vast idle watcher with a real Pearl miner payload.

## Why this image

The current watcher script is generic. It only decides whether the machine looks idle and then runs:

- `vastai set defjob ...`
- `vastai remove defjob ...`

To make that useful for PRL mining, the host needs a real miner image.

This scaffold builds a local image around the Linux `p40-miner` binary from the Open/Pearl miner project.

## Files

- `prl-miner-container/Dockerfile`
- `prl-miner-container/entrypoint.sh`

## Build on the Vast host

Copy the folder to the host and build it there:

```bash
cd ~/prl-miner-container
docker build -t local/prl-open-pearl-miner:latest .
```

If you want to pin a different miner release URL:

```bash
docker build \
  --build-arg MINER_RELEASE_URL='https://github.com/Muskwak/Open-Pearl-Miner/releases/latest/download/p40-miner-linux-x64.tar.gz' \
  -t local/prl-open-pearl-miner:latest .
```

## Quick local test

```bash
docker run --rm --gpus all local/prl-open-pearl-miner:latest \
  --wallet prl1YOURWALLET \
  --worker rigv4 \
  --pool pearl-us-central.luckypool.io:3360
```

## Optional env-based local test

```bash
docker run --rm --gpus all \
  -e PRL_WALLET=prl1YOURWALLET \
  -e PRL_WORKER=rigv4 \
  -e PRL_POOL=pearl-us-central.luckypool.io:3360 \
  local/prl-open-pearl-miner:latest
```

## Watcher example

```bash
python3 ~/vast_idle_mining_watcher.py \
  --machine-id 150421 \
  --image local/prl-open-pearl-miner:latest \
  --job-arg=--wallet \
  --job-arg=prl1YOURWALLET \
  --job-arg=--worker \
  --job-arg=rigv4 \
  --job-arg=--pool \
  --job-arg=pearl-us-central.luckypool.io:3360 \
  --price-gpu 0.15 \
  --min-idle-polls 2 \
  --dry-run \
  --once
```

## Notes

- Keep the watcher in `--dry-run` mode until the image itself has been tested with `docker run`.
- The image name is local to the host. If you move to a different host, build it there too.
- If the upstream miner changes its CLI, update `entrypoint.sh` and the watcher args together.
