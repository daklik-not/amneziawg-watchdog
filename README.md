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

## Architecture

A single long-lived **bash** process, fully **config-driven**. No daemon, no database,
no state file — all state lives in the shell's associative arrays.

One iteration of the main loop looks like this:

```
  metrics_conf.sh ───┐   (declares METRICS, OPTIONS, FORMAT, MIN/MAX/UNIT, state)
  cpu/mem/..._stat.sh ┘
         │
         ▼
   for each name in METRICS:
       get_<NAME>_inf   ──────►  CURRENT_VALUES[<NAME>]
         │
         ▼
       check_value_ge_thr       # awk:  value >= OPTIONS[<NAME>] ?
         │ (yes)
         ▼
       alert(<NAME>)            # cooldown via LAST_TTIME
         ├─► stdout  "... WARNING <NAME> = <value><unit> (threshold=...)"
         └─► echo_to_telegram    (only with -t; POST to api.telegram.org)
```

Components:

- **`system_stat.sh`** — entrypoint. Parses the CLI, detects the run mode
  (**userspace** if the `amnezia` process is found, **kernel** if `amneziawg` is in
  `/proc/modules`), validates the config, then either prints a single snapshot
  (`--once`) or loops forever calling `read_information`.
- **`metrics_conf.sh`** — the single source of truth:
  - `METRICS` — the list of metric names actually collected and alerted on;
  - `AWG_METRICS` / `AWG_METRICS_FORMAT` — extra metrics that only exist in userspace
    mode (merged into `METRICS`/`FORMAT` at startup when the `amnezia` process is found);
  - `OPTIONS` — per-metric alert thresholds **and** runtime options
    (`UPDATE_TIME`, `COOLDOWN`, `VPN_INT`);
  - `FORMAT` / `MIN` / `MAX` / `UNIT` — type, bounds and display unit used for
    config validation and output;
  - `CURRENT_VALUES` / `PREVIOUS_VALUES` — live and previous samples;
  - `get_TIME_BASED_METRICS` — the counter→rate helper.
- **`*_stat.sh`** — one file per domain (`cpu`, `mem`, `disk`, `net`, `proc`). Each
  defines `get_<METRIC>_inf` functions that read a raw value and store it in
  `CURRENT_VALUES`.

**Dispatch is by naming convention:** for every name in `METRICS` the loop calls the
function `get_<NAME>_inf`. Adding a metric means adding a name + a getter — never
editing the loop.

**Counter vs gauge:** gauges (e.g. `CPU_UTIL`) are read and stored as-is. Monotonic
counters (e.g. `NET_RX_BYTES`) are stored raw and turned into a per-second value by
`get_TIME_BASED_METRICS`, which remembers the previous sample in `PREVIOUS_VALUES`.
On the very first pass there is no previous sample, so the metric is skipped until
the next iteration (this is why `--once` takes two passes).

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

## Adding a new metric

A metric is wired in **two places only**: a getter function, and its entry in
`metrics_conf.sh`. (A third place — a `source` line + Dockerfile — is needed only if you
create a brand-new file, and the Dockerfile copies the whole `system_stat/` dir, so it
needs no change.)

**1. Write the getter.** Put it in the domain file that fits and name it exactly
`get_<NAME>_inf`. It must write the result into `CURRENT_VALUES`. A gauge is trivial:

```bash
# proc_stat.sh
function get_LOAD1_inf {
	local v
	v=$(awk '{print $1}' /proc/loadavg)
	CURRENT_VALUES["LOAD1"]=$v
}
```

For a **rate** (a monotonic counter), delegate to `get_TIME_BASED_METRICS` instead of
dividing yourself — it handles the first-pass/previous-sample logic. Copy the pattern of
`get_FORKS_PER_SEC_inf`:

```bash
function get_TCP_RETRANS_inf {
	local current_t delta_t time
	time=${OPTIONS["UPDATE_TIME"]}
	current_t=$(awk '/^Tcp:/ {v=$13} END {print v}' /proc/net/snmp)   # cumulative RetransSegs
	get_TIME_BASED_METRICS "$current_t" "TCP_RETRANS" "delta_t" "$time" || return $?
	CURRENT_VALUES["TCP_RETRANS"]=$delta_t                            # per second
}
```

**2. Register it in `metrics_conf.sh`** — all five arrays are required:

```bash
# in METRICS:
	LOAD1
# in OPTIONS (alert threshold):
	[LOAD1]=4
# in FORMAT (int|float):
	[LOAD1]="float"
# in MIN / MAX (validation bounds):
	[LOAD1]=0
	[LOAD1]=$INF
# in UNIT (display only, may be empty):
	[LOAD1]=""
```

That's it — the loop picks it up automatically. If the getter returns non-zero,
`read_information` prints `could not read metric <NAME>` and skips the alert.

**Rules of thumb**

- The function name **must** be `get_<NAME>_inf` — dispatch is by string
  (`get_func="get_${metric}_inf"`).
- `NAME` must be unique across `METRICS` + `AWG_METRICS`.
- Put the metric in `AWG_METRICS` + `AWG_METRICS_FORMAT` (not `METRICS`) if it only
  makes sense while the `amnezia` process is running — it is merged in at startup.
- Anything present in `FORMAT` is **validated at startup**: a wrong or missing
  `OPTIONS`/`MIN`/`MAX` entry makes the script exit with a config error (see
  `validate_fields`), so keep the five arrays in sync for every metric.

## Requirements

- Docker.
- The container is started with `--pid=host`, `--network=host`, `--cap-add=NET_ADMIN`,
  and mounts the host root read-only (`-v /:/host:ro`). It therefore needs
  root/docker access on the host.

## License

_(add your license here)_
