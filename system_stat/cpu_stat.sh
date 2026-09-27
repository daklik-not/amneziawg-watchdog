#!/bin/bash
source ./metrics_conf.sh

function get_CPU_LOAD { # /proc/loadvg file
	local -a loadavg
	if ! read -r -a loadavg < /proc/loadavg; then
		echo "can't read /proc/loadavg" >&2
		return 1
	fi
	echo "${loadavg[$1]}"
}

function get_CPU_LOAD5_inf {
	CURRENT_VALUES["CPU_LOAD5"]=$(get_CPU_LOAD 1)
}


function get_CPU_PROC_STAT { # /proc/stat file
	local -n out=$1
	read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
	out=([CPU]=$cpu [USER]=$user [NICE]=$nice [SYSTEM]=$system [IDLE]=$idle [IOWAIT]=$iowait [IRQ]=$irq [SOFTIRQ]=$softirq [STEAL]=$steal [GUEST]=$guest [GUEST_NICE]=$guest_nice) 
	out[TOTAL]=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
	out[UTIL]=$(( out[TOTAL] - out[IDLE] - out[IOWAIT] ))
}

function get_CPU_STAT { 
    local submetric=$1
    local rtotal rsubmetric
    local -A proc_stat
    get_CPU_PROC_STAT proc_stat
    local current_total=${proc_stat["TOTAL"]}
    local current_submetric=${proc_stat[$submetric]}

    local rc1=0 rc2=0
    get_TIME_BASED_METRICS  "$current_total" "CPU_TOTAL_$submetric" "rtotal" || rc1=$?
    get_TIME_BASED_METRICS  "$current_submetric" "CPU_${submetric}" "rsubmetric" || rc2=$?
    (( rc1 || rc2 )) && return 1

    if (( rtotal <= 0 )); then echo "Zero division attemption" >&2; return 1; fi
    
    CURRENT_VALUES["CPU_$submetric"]=$(awk -v t="$rtotal" -v i="$rsubmetric" 'BEGIN { printf "%.2f", i/t*100 }')
}

function get_CPU_UTIL_inf { get_CPU_STAT "UTIL"; }
function get_CPU_STEAL_inf { get_CPU_STAT "STEAL"; }
function get_CPU_IOWAIT_inf { get_CPU_STAT "IOWAIT"; }
function get_CPU_SYSTEM_inf { get_CPU_STAT "SYSTEM"; }
function get_CPU_SOFTIRQ_inf { get_CPU_STAT "SOFTIRQ"; }

function get_CPU_CTXT_inf {
	local current_ctxt=$(awk '/^ctxt/ { print $2; exit }' /proc/stat)
	if [[ -z ${PREVIOUS_VALUES["CPU_CTXT"]} ]]; then
		PREVIOUS_VALUES["CPU_CTXT"]=$current_ctxt
		echo "No data for calculate CPU_CTXT" >&2
		return 1
	fi
	local prev=${PREVIOUS_VALUES[CPU_CTXT]}
	local delta=$(( current_ctxt - prev ))
	local rate=$(awk -v d="$delta" -v t="${OPTIONS[UPDATE_TIME]}" 'BEGIN { printf "%.0f", d/t }')
	PREVIOUS_VALUES[CPU_CTXT]="$current_ctxt"
    CURRENT_VALUES[CPU_CTXT]="$rate"
}