#!/bin/bash
source ./metrics_conf.sh
function get_PROC_COUNT_inf {
	local process_count
	process_count=$(ps -ef | wc -l)
	CURRENT_VALUES["PROC_COUNT"]=$(( process_count - 1 ))
}

function get_PROC_ZOMBI_COUNT_inf {
	local current_value
	current_value=$(awk '{print $10}' < <(top -bn1 | grep zombie))
	CURRENT_VALUES["PROC_ZOMBI_COUNT"]=$current_value
}

function get_FD_USED_inf { # не буду добавлять в метрику поскольку оно просто не будует работать без запущенной амнезии
    local open_d 
    read -r open_d _ _ < /proc/sys/fs/file-nr
    CURRENT_VALUES["FD_USED"]=$open_d
}

function get_PROC_BLOCKED_inf {
	local current_b
	current_b=$(ps -eo state | grep -c '^D')
	CURRENT_VALUES["PROC_BLOCKED"]=$current_b
}

function get_PROC_TOTAL_THREADS_inf { get_PROC_TOTAL 2 "PROC_TOTAL_THREADS"; }
function get_PROC_RUNNING_THREADS_inf { get_PROC_TOTAL 1 "PROC_RUNNING_THREADS"; }

function get_PROC_TOTAL {
	local current_ts
	current_ts=$(awk -v b="$1" '{split($4, a, "/"); print a[b]}' /proc/loadavg)
	CURRENT_VALUES["$2"]=$current_ts
}

function get_FORKS_PER_SEC_inf {
	local current_t delta_t time
	time=${OPTIONS["UPDATE_TIME"]}
	current_t=$(awk -v t="$time" '/processes/  {print $2 / t}' /proc/stat) # делим на время с которым запускается скрипт
	get_TIME_BASED_METRICS "$current_t" "FORKS_PER_SEC" "delta_t" "$time" || return $?
	CURRENT_VALUES["FORKS_PER_SEC"]=$delta_t
}



function get_AWG_RSS_inf {
	local current_RSS
	current_RSS=$(awk '/VmRSS/ {print $2 }' /proc/${OPTIONS[PID]}/status )
	CURRENT_VALUES["AWG_RSS"]=$current_RSS
}

function get_AWG_FD_COUNT_inf {
	local current_fd
	current_fd=$(ls /proc/${OPTIONS[PID]}/fd | wc -l)
	CURRENT_VALUES["AWG_FD_COUNT"]=$current_fd
}

function get_AWG_FD_LIMIT_inf {
	local current_fd current_limit current_val
	current_limit=$(awk '/Max open files/ {print $4}' "/proc/${OPTIONS[PID]}/limits")
	current_fd=${CURRENT_VALUES["AWG_FD_COUNT"]}
	current_val=$(awk -v f="${current_fd}" -v l="${current_limit}" 'BEGIN {print (f / l) * 100}')
	CURRENT_VALUES["AWG_FD_LIMIT"]=$current_val
}

function get_AWG_CPU_inf { # сколько тиков процесс сжевал за 1 секунду в процентах

	local current_st current_ut ticks delta_st delta_ut f_value 
	ticks="${OPTIONS[TICKS]}"

	read -r current_ut current_st < <(awk '{print $14, $15}' "/proc/${OPTIONS["PID"]}/stat")
	get_TIME_BASED_METRICS "$current_ut" "AWG_CPU_UT" "delta_ut" || return $?
	get_TIME_BASED_METRICS "$current_st" "AWG_CPU_ST" "delta_st" ||  return $?
	f_value=$((delta_ut + delta_st))
	f_value=$(awk -v fv="$f_value" -v CK="$ticks" -v u="${OPTIONS["UPDATE_TIME"]}" \
         'BEGIN { printf "%.2f", fv / CK / u * 100 }')
	CURRENT_VALUES["AWG_CPU"]=$f_value
}

function get_AWG_THREAD_inf {
	local current_tc
	current_tc=$(ls "/proc/${OPTIONS["PID"]}/task" | wc -l)
	CURRENT_VALUES["AWG_THREAD"]=$current_tc
}

function get_AWG_RESTARTS_inf {
    local current_rs
    current_rs=$(grep -oP '"RestartCount":\K[0-9]+' \
        "/host-docker/amnezia/config.v2.json" 2>/dev/null)
    [[ -z "$current_rs" ]] && return 1
    CURRENT_VALUES["AWG_RESTARTS"]=$current_rs
}

