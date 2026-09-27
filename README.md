# system_stat

Lightweight system-metrics collector with **Telegram alerting**, packaged as a Docker
container. It was built for a small **AmneziaWG** (WireGuard-based) VPN/proxy host
(target machine: **1 vCPU / 1 GB RAM / 10 GB**), but the metrics themselves are generic.

## What it does

- Collects a fixed set of metrics from `/proc`, `ss`, `conntrack`, `df`, `ps`, `top`.
- Compares each value against a threshold and prints/`WARNING`s when it is exceeded.
- Optionally sends those warnings to **Telegram** (`BOT_TOKEN` + `CHAT_ID`).
- Keeps a per-metric **cooldown** so a single metric doesn't spam you.
- Runs in two modes:
  - **userspace** — the `amnezia` process is found via `pgrep`; `AWG_*` metrics are added.
  - **kernel** — the `amneziawg` module is present in `/proc/modules`; `AWG_*` are skipped.
- `--once` prints a single snapshot instead of entering the endless loop.

## Layout

```
Dockerfile                     # alpine:3.20 image, ENTRYPOINT = system_stat.sh
rebuild.sh                     # build + run helper (docker rm/build/run)
system_stat/
  system_stat.sh               # CLI, help, main loop, alerting
  metrics_conf.sh              # metric list, thresholds (OPTIONS), FORMAT/MIN/MAX/UNIT
  cpu_stat.sh                  # CPU getters
  mem_stat.sh                  # memory / swap getters
  disk_stat.sh                 # disk space / inode / IO-util getters
  net_stat.sh                  # network + conntrack getters
  proc_stat.sh                 # process / thread / fork getters
```

## Usage

Normally you run it through `rebuild.sh`, which builds the image and passes the
arguments / environment through to the container:

```bash
./rebuild.sh -vi amn0            # infinite loop, alerts enabled if -t given
./rebuild.sh -vi amn0 --once     # one snapshot, no alerts, exit 0
./rebuild.sh -- --help           # show the help text
```

Or run the script directly:

```bash
system_stat/system_stat.sh -vi <iface> [--once] [-t|--telegram]
```

`-vi <iface>` is **required** — it is the VPN interface (e.g. `amn0`, `wg0`) used by the
`NET_*` metrics. See `ip -br link`.

## Configuration

- **Thresholds, polling interval and cooldown** live in `system_stat/metrics_conf.sh`
  (the `OPTIONS` array). Each metric is documented there.
- `UPDATE_TIME` must be **≥ 1**; the shipped default is `60` seconds.
- **Telegram:** export `BOT_TOKEN` and `CHAT_ID` in your environment before running
  `rebuild.sh` — they are forwarded to the container with `docker run -e` and are never
  stored in the repo:

  ```bash
  BOT_TOKEN=123456:ABC CHAT_ID=987654321 ./rebuild.sh -vi amn0
  ```

> Keep real secrets out of git. If `BOT_TOKEN`/`CHAT_ID` are unset the script still runs,
> but alerts are not delivered (a warning is printed).

## Requirements

- Docker.
- The container is started with `--pid=host`, `--network=host`, `--cap-add=NET_ADMIN`,
  and mounts the host root read-only (`-v /:/host:ro`). It therefore needs
  root/docker access on the host.

## License

_(add your license here)_
