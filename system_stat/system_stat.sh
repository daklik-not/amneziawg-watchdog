#!/bin/bash

source ./metrics_conf.sh
source ./cpu_stat.sh
source ./mem_stat.sh
source ./net_stat.sh
source ./disk_stat.sh
source ./proc_stat.sh
# METRICS — a subset of FORMAT: only what is actually monitored and alerted on.
# UPDATE_TIME/COOLDOWN are validated via FORMAT but do not participate in read_information/alert.

function show_help {
	cat <<EOF
system_stat — metrics collection and alerting for AmneziaWG (target host: 1 vCPU / 1 GB RAM / 10 GB).

USAGE
    system_stat.sh -vi <iface> [--once]

    The script is normally not run directly, but via rebuild.sh, which
    builds the image and passes it arguments and environment variables:

        ./rebuild.sh -vi amn0
        ./rebuild.sh -vi amn0 --once
        ./rebuild.sh -- --help

OPTIONS
    -vi, --vpn-int <iface>   Required. VPN interface used to read the NET_* metrics,
                             e.g. amn0 or wg0. See: ip -br link.
    -o,  --once              A single snapshot of all metrics to stdout, without
                             Telegram alerts and without entering the endless loop. Exit 0.
                             The first pass initializes the counter metrics, the second
                             (after UPDATE_TIME seconds) yields real values.
    -h,  --help              Show this help and exit. Does not require -vi
                             and does not check for the VPN process.
	-t,  --telegram          Enables Telegram alerts. Requires a configured token;
							 the script will not terminate, alerts simply won't reach Telegram
							
ENVIRONMENT (passed to the container via docker run -e)
    ROOT_PATH    Root of the mounted host filesystem. In the container: /host.
                 Used by the DISK_ROOT_PCT, DISK_INODE_PCT,
                 DISK_IO_UTIL_PCT metrics. When run directly without ROOT_PATH,
                 the current / is used.
    BOT_TOKEN    Telegram bot token. Without it alerts go nowhere —
                 the script still runs, but sendMessage returns an error.
    CHAT_ID      Chat/channel ID for alerts.

EXIT CODES
    0           normal completion, --help, --once
    1           argument error, missing VPN process, or invalid
                values in OPTIONS (see validate_fields)

NOTES
    - The script runs in two modes: userspace (the amnezia process is found
      via pgrep, AWG_* metrics are added automatically) and kernel
      (the amneziawg module is in /proc/modules, AWG_* are not collected).
    - Alert thresholds and the polling interval are set in metrics_conf.sh
      (the OPTIONS array). Per-metric comments are there as well.
    - Cooldown between repeated alerts for the same metric —
      OPTIONS[COOLDOWN], default ${OPTIONS[COOLDOWN]} s.
EOF
}

function read_metrics_silent {
	local metric get_func
	for metric in "${METRICS[@]}"; do
		get_func="get_${metric}_inf"
		"$get_func" >/dev/null 2>&1 || true
	done
}

function once {
	local metric get_func value thr unit status
	local interval="${OPTIONS[UPDATE_TIME]}"
	(( interval < 1 )) && interval=1

	# First pass — initializes PREVIOUS_VALUES for the counter metrics.
	read_metrics_silent
	sleep "$interval"
	# Second pass — real values and rate.
	read_metrics_silent

	printf '\n=== system_stat snapshot  %s ===\n' "$(date '+%H:%M:%S | %d.%m.%Y')"
	printf 'iface=%s  update_time=%ss  cooldown=%ss  mode=%s\n\n' \
		"${OPTIONS[VPN_INT]}" "${OPTIONS[UPDATE_TIME]}" "${OPTIONS[COOLDOWN]}" "${OPTIONS[MODE]:-?}"

	printf '%-26s %16s %16s %6s\n' "METRIC" "VALUE" "THRESHOLD" "STATE"
	printf '%-26s %16s %16s %6s\n' "--------------------------" "----------------" "----------------" "------"

	local over=0 total=0
	for metric in "${METRICS[@]}"; do
		total=$((total + 1))
		value="${CURRENT_VALUES[$metric]-}"
		thr="${OPTIONS[$metric]-0}"
		unit="${UNIT[$metric]-}"

		if [[ -z "$value" ]]; then
			status="N/A"
			value="-"
		elif awk -v v="$value" -v t="$thr" 'BEGIN {exit !(v >= t)}'; then
			status="OVER"
			over=$((over + 1))
		else
			status="ok"
		fi

		printf '%-26s %16s %16s %6s\n' "${metric}${unit}" "$value" "${thr}${unit}" "$status"
	done

	printf '\n%d metric(s), %d over threshold.\n' "$total" "$over"
}

function read_information {
	local metric_information get_func
	for metric in "${METRICS[@]}"; do
		get_func="get_${metric}_inf"
		#echo "$metric" >&2
		if ! "$get_func"; then 
				echo "could not read metric $metric" >&2
			continue
		fi
		check_value_ge_thr "$metric" 
	done
}

function check_value_ge_thr {
	local metric_name="$1" 
	if awk "BEGIN {exit !( ${CURRENT_VALUES[$metric_name]} >= ${OPTIONS[$metric_name]} )}"; then
		alert "$metric_name" 
	fi
}

function echo_to_telegram {
	local MESSAGE=$1
	curl -s -X POST \
		"https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
		-d chat_id="${CHAT_ID}" \
		-d parse_mode="Markdown" \
		-d text="${MESSAGE}" >/dev/null
}

function alert {
	local metric_name="$1" 
	local time time_difference
	time=$(date +%s)
	time_difference=$(( time - LAST_TTIME["$metric_name"] ))

	if [[ $time_difference -gt ${OPTIONS[COOLDOWN]} ]]; then
		local msg
		msg="$(date '+%H:%M:%S | %d.%m.%Y') WARNING ${metric_name} = ${CURRENT_VALUES[$metric_name]}${UNIT[$metric_name]} (threshold=${OPTIONS[$metric_name]}${UNIT[$metric_name]})"
		if [[ $IS_TELEGRAM -eq 1 ]];then
			echo_to_telegram "$msg"
		fi
		echo "$msg"
		LAST_TTIME["$metric_name"]=$time
	fi
}


# ============================================================
# VALIDATION
# ============================================================

function is_int {
	[[ "$1" =~ ^([1-9][0-9]*|0)$ ]]
}

function is_float {
	[[ "$1" =~ ^(([1-9][0-9]*|0)(\.[0-9]+)?)$ ]]
}


function in_range {
	local value=$1 min=$2 max=$3
	awk "BEGIN {exit !($value >= $min && $value <= $max)}"
}

function validate_fields {
	local result=0
	for field in "${!FORMAT[@]}"; do
		local current_tv=${OPTIONS[$field]}
		local foo_to_check="is_${FORMAT[$field]}"
		local min="${MIN[$field]}"
		local max="${MAX[$field]}"
		if [[ ${FORMAT[$field]} == "string" ]]; then
			continue
		fi
		if ! $foo_to_check "$current_tv" || ! in_range "$current_tv" "$min" "$max"; then
			echo "invalid value for ${field} (see OPTIONS in metrics_conf.sh)" >&2
			result=1
		fi
	done
	return $result
}

function cleanup {
	echo "Exiting script..."
	case "$1" in
		SIGHUP) exit 129 ;;
		SIGINT) exit 130 ;;
		SIGTERM) exit 143 ;;
		*) exit 1 ;;
	esac
}

function main {
	trap 'cleanup SIGTERM' SIGTERM
	trap 'cleanup SIGINT' SIGINT
	trap 'cleanup SIGHUP' SIGHUP

	while [[ $# -gt 0 ]]; do
		case "$1" in
			-vi|--vpn-int)
				OPTIONS["VPN_INT"]="$2"
				OPTIONS["VPN_INT_IS_CLI"]=1
				shift 2
				;;
			-h|--help)
				show_help
				exit 0
				;;
			-o|--once)
				IS_ONCE=1
				shift 1
				;;
			-t|--telegram)
				IS_TELEGRAM=1
				shift 1
				;;
			*)
				echo "invalid argument: $1" >&2
				exit 1
				;;
		esac
	done

	OPTIONS[TICKS]=$(getconf CLK_TCK)
	if grep -q '^amneziawg' /proc/modules; then
		OPTIONS["MODE"]="kernel"
	elif OPTIONS["PID"]=$(pgrep -o "amnezia") && [ -n "${OPTIONS["PID"]}" ]; then
		OPTIONS["MODE"]="userspace"
		METRICS+=("${AWG_METRICS[@]}")
		for key in "${!AWG_METRICS_FORMAT[@]}"; do
			FORMAT["$key"]=${AWG_METRICS_FORMAT["$key"]}
		done
	else
		echo "no AmneziaWG VPN process found (and the amneziawg kernel module is not loaded)" >&2
		exit 1
	fi

	if [[ -z ${OPTIONS["VPN_INT"]} ]]; then
		echo "no VPN interface given, use: -vi <iface>" >&2
		exit 1
	fi
	if ! validate_fields; then
		exit 1
	fi

	if [[ $IS_ONCE -eq 1 ]]; then
		once
		exit 0
	fi

	while true; do
		read_information
		sleep "${OPTIONS[UPDATE_TIME]}"
	done
}

main "$@"