#!/bin/bash
source ./metrics_conf.sh

#это все серверный TCP -> то есть сервер сам куда-то обращается по TCP.
function SERV_TCP_GET_STAT {
    local -n out=$1
    local STATE ev_else
    while read -r STATE ev_else; do
        STATE="${STATE//-/_}"
        [[ -z "$STATE" ]] && continue
        out["$STATE"]=$(( ${out["$STATE"]} + 1 ))
    done < <(ss -at | tail -n +2)
}

function get_SERV_TCP_STAT {
    local -A STATE_COUNT
    SERV_TCP_GET_STAT STATE_COUNT
    CURRENT_VALUES["SERV_TCP_$1"]=${STATE_COUNT["$1"]:-0}
}

function get_SERV_TCP_LISTEN_inf     { get_SERV_TCP_STAT "LISTEN"; }

#не имеет смысла с использование conntrack, \
#но можно раскоментить, чтобы смотреть именно сокеты, а не соединения

#function get_SERV_TCP_SYN_SENT_inf   { get_SERV_TCP_STAT "SYN_SENT"; }
#function get_SERV_TCP_SYN_RECV_inf   { get_SERV_TCP_STAT "SYN_RECV"; }
#function get_SERV_TCP_ESTAB_inf      { get_SERV_TCP_STAT "ESTAB"; }
#function get_SERV_TCP_TIME_WAIT_inf  { get_SERV_TCP_STAT "TIME_WAIT"; }
#function get_SERV_TCP_CLOSE_WAIT_inf { get_SERV_TCP_STAT "CLOSE_WAIT"; }

## проблема с тем, что я не знаю, какой предполагаемый линк speed,  поскольку на VPS его не пишут, а какие-то свои предположеения я просто не могу делаь
function NET_STAT {
    local current_value delta metric=$1 metric_name=$2
    current_value=$(awk -v m="$metric" -v i="${OPTIONS["VPN_INT"]}" '$1 ~ i ":" {print $m}' /proc/net/dev)
    get_TIME_BASED_METRICS "$current_value" "NET_${metric_name}" delta "${OPTIONS[UPDATE_TIME]}" || return $?
    CURRENT_VALUES["NET_$metric_name"]=$delta
}

function get_NET_RX_BYTES_inf { NET_STAT 2 "RX_BYTES" ;}
function get_NET_TR_BYTES_inf { NET_STAT 10 "TR_BYTES" ; }
function get_NET_RX_DROPPED_inf  { NET_STAT 5 "RX_DROPPED" ;}
function get_NET_TR_DROPPED_inf  { NET_STAT 13 "TR_DROPPED" ;}



# можно использовать для получения информации из файла snmp
function get_NET_SNMP { 
    local -n out=$1
    local -a metric_array metric_values
    {
        read -ra metric_array 
        read -ra metric_values
    } < <(grep "^$2:" /proc/net/snmp)

    for ((i=0; i<${#metric_array[@]}; i++)); do
        out["${metric_array[$i]}"]="${metric_values[$i]}"
    done
}

# ФАКТИЧЕСКИ ТОЖЕ ТОЛЬКО ДЛЯ СОЕДИНЕНИЙ СЕРВЕРА
# ЕСЛИ ЧЕКАЕМ НЕ ВПН СЕРВЕР, ТО ЕСТЬ СМЫСЛ ИНАЧЕ НЕТ

#function get_NET_SERV_TCP_RETRANS_inf {
#    local -A local_net_stat 
#    local delta_RS delta_OS
#    get_NET_SNMP local_net_stat Tcp
#    
#    local current_RS=${local_net_stat["RetransSegs"]}
#    local current_OS=${local_net_stat["OutSegs"]}
#    
#    local rc1=0 rc2=0
#    get_TIME_BASED_METRICS "$current_RS" "NET_SERV_TCP_RETRANS" delta_RS || rc1=$?
#    get_TIME_BASED_METRICS "$current_OS" "NET_SERV_TCP_OUT"     delta_OS || rc2=$?
#    (( rc1 || rc2 )) && return 1
#
#    if (( delta_OS == 0 )); then
#        CURRENT_VALUES[NET_SERV_TCP_RETRANS]=0
#        return 0
#    fi
#    local current_value
#    current_value=$(awk -v a="$delta_RS" -v b="$delta_OS" 'BEGIN {print (a / b) * 100}')
#    CURRENT_VALUES[NET_SERV_TCP_RETRANS]=$current_value # здесь мне надо 2 дельты
#}

#function get_NET_SERV_TCP_PASSIVE_OPENS_inf {
#    local -A local_net_stat
#    local delta_PO
#    get_NET_SNMP local_net_stat Tcp
#    local current_PO=${local_net_stat["PassiveOpens"]}
#    get_TIME_BASED_METRICS "$current_PO" "NET_SERV_TCP_PASSIVE_OPENS" delta_PO || return $?
#    CURRENT_VALUES[NET_SERV_TCP_PASSIVE_OPENS]=$delta_PO
#}
#
#function get_NET_SERV_TCP_LISTEN_OVERFLOWS_inf {
#	local delta current_value
#	current_value=$(awk '/TcpExtListenOverflows/ {print $2}' < <(nstat -az))
#	get_TIME_BASED_METRICS "$current_value" "NET_SERV_TCP_LISTEN_OVERFLOWS" "delta" || return $?
#	CURRENT_VALUES[NET_SERV_TCP_LISTEN_OVERFLOWS]=$delta
#}
##остановился вот здесь 


function get_NET_SOCKET_COUNT_inf {
	local sc
	sc=$(awk '/Total:/ {print $2}' < <(ss -s))
	CURRENT_VALUES["NET_SOCKET_COUNT"]=$sc
}


# UDP МЕТРИКИ
# ВСЕ UDP МЕТРИКИ ОБЩИЕ, ПОЭТОМУ СМЫСЛ ЕСТЬ

function get_UDP_RCVBUF_ERR_inf {  get_UDP_METRIC_inf  "RcvbufErrors" "UDP_RCVBUF_ERR"; }
function get_UDP_SNDBUF_ERR_inf {  get_UDP_METRIC_inf  "SndbufErrors" "UDP_SNDBUF_ERR"; }
function get_UDP_IN_ERRORS_inf {  get_UDP_METRIC_inf  "InErrors" "UDP_IN_ERRORS"; }

function get_UDP_METRIC_inf {
	local -A local_net_stat
    local current_value delta_ER
	get_NET_SNMP "local_net_stat" "Udp"
	current_value=${local_net_stat["$1"]}
	get_TIME_BASED_METRICS "$current_value" "$2" "delta_ER" "${OPTIONS[UPDATE_TIME]}" || return $?
	CURRENT_VALUES["$2"]=$delta_ER
}

########################## КЛИЕНТСКИЙ TCP ##########################
# Чтобы отслеживать клиентские TCP соединения
#надо смотреть на соединения внутри UDP сокета
function get_CLIENT_TCP_ESTABL_inf {
    local current_e
    current_e=$(conntrack -L -p tcp --state ESTABLISHED 2>/dev/null | wc -l)
    CURRENT_VALUES["CLIENT_TCP_ESTABL"]=$current_e
}

function get_CLIENT_TCP_USED_inf {
    local cur_min cur_max value
    cur_min=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    cur_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    value=$(awk -v mi="$cur_min" -v ma="$cur_max" 'BEGIN {print (mi / ma) * 100}')
    CURRENT_VALUES["CLIENT_TCP_USED"]=$value
}

function get_CLIENT_TCP_DROP_inf {
    local current_d delta_d
    current_d=$(conntrack -S | grep -oP 'drop=\K\d+' 2> /dev/null  |  awk '{s+=$1} END {print s+0}')
    get_TIME_BASED_METRICS "$current_d" "CLIENT_TCP_DROP" "delta_d"  "${OPTIONS[UPDATE_TIME]}" || return $?
    CURRENT_VALUES["CLIENT_TCP_DROP"]=$delta_d
}

function get_CLIENT_TCP_TIME_WAIT_inf {
    local current_tw
    current_tw=$(conntrack -L -p tcp --state TIME_WAIT 2> /dev/null  | wc -l)
    CURRENT_VALUES["CLIENT_TCP_TIME_WAIT"]=$current_tw
}

function get_CLIENT_TCP_CLOSE_WAIT_inf {
    local current_tw
    current_tw=$(conntrack -L -p tcp --state CLOSE_WAIT 2> /dev/null | wc -l)
    CURRENT_VALUES["CLIENT_TCP_CLOSE_WAIT"]=$current_tw
}