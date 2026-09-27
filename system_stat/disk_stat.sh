#!/bin/bash
source ./metrics_conf.sh



function get_ROOT_USED {
    local flag1=$1 flag2=$2
    df "-P${flag1}" "$ROOT_PATH" | awk -v f2="$flag2" 'NR==2 { gsub("%", "", $f2); print $f2 }'
}

function get_DISK_ROOT_PCT_inf {
    CURRENT_VALUES["DISK_ROOT_PCT"]=$(get_ROOT_USED "" 5)
}

function get_DISK_INODE_PCT_inf {
    CURRENT_VALUES["DISK_INODE_PCT"]=$(get_ROOT_USED "i" 5)
}

function get_DEVICE_NAME {
    local device_name
    device_name="$(get_ROOT_USED "" 1)"
	device_name="${device_name#/dev/}"
	echo "$device_name"
}

function get_DISK_IO_UTIL_PCT_inf {
    local delta_c delta_t timestamp current_c
    current_c=$(awk -v dn="$(get_DEVICE_NAME)" '$3 == dn {print $13}' /proc/diskstats)
    [[ -z "$current_c" ]] && return 1
    timestamp=$(date +%s000) 
    get_TIME_BASED_METRICS "$current_c" "DISK_IO_UTIL_PCT" delta_c || return $?
    get_TIME_BASED_METRICS "$timestamp" "DISK_TIME" delta_t || return $?
    (( delta_t <= 0 )) && return 1
    CURRENT_VALUES["DISK_IO_UTIL_PCT"]=$(awk -v c="$delta_c" -v t="$delta_t" 'BEGIN { printf "%.2f", c / t * 100 }')
}

