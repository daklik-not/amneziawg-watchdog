#!/bin/bash
source ./metrics_conf.sh


# MEMORY BLOCK

function parse_MEM_INFO {
	local -n out=$1
	local key value unit
	while read -r key value unit; do
		key="${key%:}"
		out["$key"]=$value
	done < "/proc/meminfo"
}


function get_MEM_USED_PCT_inf {
	local -A MEM_INFO
	parse_MEM_INFO MEM_INFO
	CURRENT_VALUES["MEM_USED_PCT"]=$(awk -v t="${MEM_INFO[MemTotal]}" -v a="${MEM_INFO[MemAvailable]}" 'BEGIN {print (t - a) / t * 100}')
}

function get_MEM_OOM_COUNT_inf {
    local current_value delta
    current_value=$(awk '/^oom_kill /{print $2}' /proc/vmstat)
    get_TIME_BASED_METRICS "$current_value" "MEM_OOM_COUNT" delta "${OPTIONS[UPDATE_TIME]}" || return $?
    CURRENT_VALUES["MEM_OOM_COUNT"]=$delta
}


function get_SWAP_USED_PCT_inf {
	local -A MEM_INFO
	parse_MEM_INFO MEM_INFO
	if [[ ${MEM_INFO[SwapTotal]} -eq 0 ]]; then # no swap
		CURRENT_VALUES["SWAP_USED_PCT"]=0
		return 0
	fi
	CURRENT_VALUES["SWAP_USED_PCT"]=$(awk -v t="${MEM_INFO[SwapTotal]}" -v a="${MEM_INFO[SwapFree]}" 'BEGIN {print (t - a) / t * 100}')
}


