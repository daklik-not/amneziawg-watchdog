#!/bin/bash

INF=100000000000

BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"

declare -A LAST_TTIME # time of the last alert for this metric (used for cooldown)

declare METRICS=(
	CPU_LOAD5         # 5-minute load average — a smoothed indicator of whether there is a CPU queue. Grows faster than CPU_UTIL reacts and accounts for processes in D-state (I/O wait)
	MEM_USED_PCT      # % of RAM used — a direct OOM predictor. Critical for a proxy: when memory runs low the kernel starts killing processes, including the proxy itself
	SWAP_USED_PCT     # % of swap used — if swap keeps growing the machine is already under pressure. When swapping, proxy latency goes through the roof because pages are read from disk
	MEM_OOM_COUNT     # OOM-killer invocation counter — a counter, the rate matters. One tick = someone died; if it was the proxy, clients already got a 502. The harshest memory alert
	CPU_CTXT          # Context switches — a counter, rate/sec matters. Abnormally high = scheduler thrashing (many short-lived processes/threads), latency grows
	DISK_ROOT_PCT     # % of space used on /. A disk at 100% breaks logs, socket files, PID files — the proxy won't be able to write, and under load won't accept connections either
	DISK_INODE_PCT    # % of inodes used on /. Inodes run out before space does with millions of small files (logs, cache, sessions). The proxy loses the ability to create sockets/logs even though df reports free space
	DISK_IO_UTIL_PCT  # % of time the disk was busy with at least one operation. Counter-based (io_ticks from /proc/diskstats). At 100% the queue grows, latency skyrockets, iowait gets noisy. A direct indicator that the disk is the bottleneck
	PROC_COUNT        # Total number of processes. A sharp rise = fork bomb, worker leak, zombie accumulation. Steady growth = a slow leak bug in the application
	PROC_ZOMBI_COUNT  # Number of zombie processes. Growth = the parent process isn't calling wait() for its children — on a small system with 1 GB RAM this quickly eats up the process/PID table
	PROC_BLOCKED      # Processes in state D (uninterruptible sleep, usually disk/network storage). Sustained growth = disk/network can't keep up, processes hang
	PROC_TOTAL_THREADS   # Total number of threads in the system (from /proc/loadavg). On a small machine a growing thread count = a thread/worker leak eating up the already scarce RAM
	PROC_RUNNING_THREADS # Number of threads in the running/runnable state right now (from /proc/loadavg). With 1 vCPU this is effectively the queue for the single core
	FORKS_PER_SEC     # Number of fork() calls per second — a counter, the rate matters. A sharp jump = fork bomb or pathological service behavior (respawn loop).                # IMPORTANT: this script itself forks many subprocesses (ps/ss/df/awk/conntrack) on every iteration — account for that in the baseline; the threshold below already has headroom for this self-load
	CPU_UTIL          # Total CPU utilization in % — a general indicator of how the system breathes. It is usually the first thing people look at during degradation
	CPU_STEAL         # Time stolen by the hypervisor — on a VPS it reveals noisy neighbors. If >5–10% your machine is slow not because of your code, and tuning locally is pointless
	CPU_SOFTIRQ       # softirq handling (mostly network, NET_RX/TX). For a proxy it is a direct indicator: if softirq is high the kernel can't keep up with packet processing, drops and retransmissions grow
	CPU_SYSTEM        # Time in kernel space. Grows with syscall storms, high network I/O, mutexes. For a proxy it is often more important than user time — the bottleneck is in the kernel, not in the code
	CPU_IOWAIT        # % of CPU time spent waiting for I/O to complete. With 1 vCPU this directly "eats" the single core — high iowait = the disk stalls the whole process, not just its own I/O
	SERV_TCP_LISTEN   # Sockets in LISTEN — how many ports/backends are being listened on. conntrack doesn't see LISTEN, so we take it from ss. If the number suddenly drops — one of the workers died and didn't come back up
	NET_RX_BYTES      # Bytes received over the network — a counter, the rate matters. Shows inbound traffic; a sharp rise/fall helps you understand whether load is flowing at all
	NET_TR_BYTES      # Bytes transmitted over the network — a counter, the rate matters. Shows outbound traffic; together with NET_RX_BYTES it gives a picture of network activity
	NET_RX_DROPPED    # Inbound packets dropped by the kernel — a counter, the rate matters. Grows when NIC buffers/queues overflow: packets don't reach the proxy, clients see timeouts
	NET_TR_DROPPED    # Outbound packets dropped by the kernel — a counter, the rate matters. Grows when TX queues overflow: replies don't leave, connections hang in retransmission
	CLIENT_TCP_ESTABL     # Number of TCP connections in ESTABLISHED in conntrack — including the transit traffic of VPN clients and the server's local connections. The main load metric
	CLIENT_TCP_USED       # % fill of the conntrack table (nf_conntrack_count / nf_conntrack_max). Approaching 100% = new connections will start being dropped
	CLIENT_TCP_DROP       # Counter of packets dropped by conntrack due to table overflow. Rate > 0 = clients are already losing connections
	CLIENT_TCP_TIME_WAIT  # TCP connections in TIME_WAIT in conntrack. Accumulation = many short-lived connections going through the server
	CLIENT_TCP_CLOSE_WAIT # TCP connections in CLOSE_WAIT in conntrack. Sustained growth = FD leak
	NET_SOCKET_COUNT  # Total sockets in the system (TCP+UDP+UNIX). A sharp rise = socket leak, approaching fs.file-max. A key indicator of FD exhaustion
	UDP_RCVBUF_ERR    # Packets dropped by the kernel: the UDP socket receive buffer is full — a counter, the rate matters. For a VPN carrying games/video it is a direct indicator of losses inside the tunnel
	UDP_SNDBUF_ERR    # Packets dropped by the kernel: the UDP socket send buffer is full — a counter, the rate matters. Same as RCVBUF but in the outbound direction
	UDP_IN_ERRORS     # Inbound UDP packet errors (other than checksum) — a counter, the rate matters. Corrupted packets, L2/L3 problems; rare, but useful for diagnostics
)

declare AWG_METRICS=(
	AWG_RSS
	AWG_FD_COUNT
	AWG_FD_LIMIT
	AWG_CPU
	AWG_THREAD
	AWG_RESTARTS
)

declare -A AWG_METRICS_FORMAT=(
	[AWG_RSS]="int"
	[AWG_FD_COUNT]="int"
	[AWG_FD_LIMIT]="float"
	[AWG_CPU]="float"
	[AWG_THREAD]="int"
	[AWG_RESTARTS]="int"
)

IS_ONCE=0
IS_TELEGRAM=0
# Alert thresholds + runtime options.
# An alert fires when the metric value >= its threshold; the values below are
# example defaults for the 1 vCPU / 1 GB target host - tune them for yours.

declare -A OPTIONS=(
	[NET_RX_BYTES]=125000000
	[NET_TR_BYTES]=125000000
	[NET_RX_DROPPED]=1
	[NET_TR_DROPPED]=1
	[VPN_INT]=""
	[CPU_LOAD5]=2
	[MEM_USED_PCT]=90
	[SWAP_USED_PCT]=50
	[MEM_OOM_COUNT]=1
	[DISK_ROOT_PCT]=90
	[DISK_INODE_PCT]=90
	[DISK_IO_UTIL_PCT]=90
	[PROC_COUNT]=1000
	[PROC_ZOMBI_COUNT]=1
	[PROC_BLOCKED]=5
	[PROC_TOTAL_THREADS]=2000
	[PROC_RUNNING_THREADS]=16
	[FORKS_PER_SEC]=1000
	[UPDATE_TIME]=60
	[COOLDOWN]=300
	[CPU_UTIL]=90
	[CPU_IOWAIT]=20
	[CPU_STEAL]=10
	[CPU_SYSTEM]=80
	[CPU_SOFTIRQ]=50
	[CPU_CTXT]=100000
	[SERV_TCP_LISTEN]=1000
	[CLIENT_TCP_ESTABL]=50000
	[CLIENT_TCP_USED]=80
	[CLIENT_TCP_DROP]=1
	[CLIENT_TCP_TIME_WAIT]=50000
	[CLIENT_TCP_CLOSE_WAIT]=500
	[NET_SOCKET_COUNT]=50000
	[UDP_RCVBUF_ERR]=1
	[UDP_SNDBUF_ERR]=1
	[UDP_IN_ERRORS]=1
	[AWG_RSS]=200000
	[AWG_FD_COUNT]=10000
	[AWG_FD_LIMIT]=90
	[AWG_CPU]=90
	[AWG_THREAD]=500
	[AWG_RESTARTS]=1
)

declare -A CURRENT_VALUES=(
)
declare -A PREVIOUS_VALUES=(

)

declare -A FORMAT=(
	[NET_RX_BYTES]="int"
	[NET_TR_BYTES]="int"
	[NET_RX_DROPPED]="int"
	[NET_TR_DROPPED]="int"
	[VPN_INT]="string"
	[CPU_LOAD5]="float"
	[MEM_USED_PCT]="int"
	[SWAP_USED_PCT]="float"
	[MEM_OOM_COUNT]="int"
	[DISK_ROOT_PCT]="int"
	[DISK_INODE_PCT]="int"
	[DISK_IO_UTIL_PCT]="float"
	[PROC_COUNT]="int"
	[PROC_ZOMBI_COUNT]="int"
	[PROC_BLOCKED]="int"
	[PROC_TOTAL_THREADS]="int"
	[PROC_RUNNING_THREADS]="int"
	[FORKS_PER_SEC]="float"
	[UPDATE_TIME]="int"
	[COOLDOWN]="int"
	[CPU_UTIL]="float"
	[CPU_IOWAIT]="float"
	[CPU_STEAL]="float"
	[CPU_SYSTEM]="float"
	[CPU_SOFTIRQ]="float"
	[CPU_CTXT]="float"
	[SERV_TCP_LISTEN]="int"
	[CLIENT_TCP_ESTABL]="int"
	[CLIENT_TCP_USED]="float"
	[CLIENT_TCP_DROP]="int"
	[CLIENT_TCP_TIME_WAIT]="int"
	[CLIENT_TCP_CLOSE_WAIT]="int"
	[NET_SOCKET_COUNT]="int"
	[UDP_RCVBUF_ERR]="int"
	[UDP_SNDBUF_ERR]="int"
	[UDP_IN_ERRORS]="int"
)

declare -A MIN=(
	[NET_RX_BYTES]=0
	[NET_TR_BYTES]=0
	[NET_RX_DROPPED]=0
	[NET_TR_DROPPED]=0
	[CPU_LOAD5]=0
	[MEM_USED_PCT]=0
	[SWAP_USED_PCT]=0
	[MEM_OOM_COUNT]=0
	[DISK_ROOT_PCT]=0
	[DISK_INODE_PCT]=0
	[DISK_IO_UTIL_PCT]=0
	[PROC_COUNT]=0
	[PROC_ZOMBI_COUNT]=0
	[PROC_BLOCKED]=0
	[PROC_TOTAL_THREADS]=0
	[PROC_RUNNING_THREADS]=0
	[FORKS_PER_SEC]=0
	[UPDATE_TIME]=1
	[COOLDOWN]=0
	[CPU_UTIL]=0
	[CPU_IOWAIT]=0
	[CPU_STEAL]=0
	[CPU_SYSTEM]=0
	[CPU_SOFTIRQ]=0
	[CPU_CTXT]=0
	[SERV_TCP_LISTEN]=0
	[CLIENT_TCP_ESTABL]=0
	[CLIENT_TCP_USED]=0
	[CLIENT_TCP_DROP]=0
	[CLIENT_TCP_TIME_WAIT]=0
	[CLIENT_TCP_CLOSE_WAIT]=0
	[NET_SOCKET_COUNT]=0
	[UDP_RCVBUF_ERR]=0
	[UDP_SNDBUF_ERR]=0
	[UDP_IN_ERRORS]=0
	[AWG_RSS]=0
	[AWG_FD_COUNT]=0
	[AWG_FD_LIMIT]=0
	[AWG_CPU]=0
	[AWG_THREAD]=0
	[AWG_RESTARTS]=0
)

declare -A MAX=(
	[NET_RX_BYTES]=$INF
	[NET_TR_BYTES]=$INF
	[NET_RX_DROPPED]=$INF
	[NET_TR_DROPPED]=$INF
	[CPU_LOAD5]=$INF
	[MEM_USED_PCT]=100
	[SWAP_USED_PCT]=100
	[MEM_OOM_COUNT]=$INF
	[DISK_ROOT_PCT]=100
	[DISK_INODE_PCT]=100
	[DISK_IO_UTIL_PCT]=100
	[PROC_COUNT]=$INF
	[PROC_ZOMBI_COUNT]=$INF
	[PROC_BLOCKED]=$INF
	[PROC_TOTAL_THREADS]=$INF
	[PROC_RUNNING_THREADS]=$INF
	[FORKS_PER_SEC]=$INF
	[UPDATE_TIME]=$INF
	[COOLDOWN]=$INF
	[CPU_UTIL]=100
	[CPU_IOWAIT]=100
	[CPU_STEAL]=100
	[CPU_SYSTEM]=100
	[CPU_SOFTIRQ]=100
	[CPU_CTXT]=$INF
	[SERV_TCP_LISTEN]=$INF
	[CLIENT_TCP_ESTABL]=$INF
	[CLIENT_TCP_USED]=100
	[CLIENT_TCP_DROP]=$INF
	[CLIENT_TCP_TIME_WAIT]=$INF
	[CLIENT_TCP_CLOSE_WAIT]=$INF
	[NET_SOCKET_COUNT]=$INF
	[UDP_RCVBUF_ERR]=$INF
	[UDP_SNDBUF_ERR]=$INF
	[UDP_IN_ERRORS]=$INF
	[AWG_RSS]=$INF
	[AWG_FD_COUNT]=$INF
	[AWG_FD_LIMIT]=$INF
	[AWG_CPU]=100
	[AWG_THREAD]=$INF
	[AWG_RESTARTS]=$INF
)

# Units — used only for output formatting (once, alert); they do not participate in validation
declare -A UNIT=(
	[NET_RX_BYTES]="B"
	[NET_TR_BYTES]="B"
	[NET_RX_DROPPED]="pkt"
	[NET_TR_DROPPED]="pkt"
	[CPU_LOAD5]=""
	[MEM_USED_PCT]="%"
	[SWAP_USED_PCT]="%"
	[MEM_OOM_COUNT]=""
	[DISK_ROOT_PCT]="%"
	[DISK_INODE_PCT]="%"
	[DISK_IO_UTIL_PCT]="%"
	[PROC_COUNT]=""
	[PROC_ZOMBI_COUNT]=""
	[PROC_BLOCKED]=""
	[PROC_TOTAL_THREADS]=""
	[PROC_RUNNING_THREADS]=""
	[FORKS_PER_SEC]=""
	[UPDATE_TIME]="s"
	[COOLDOWN]="s"
	[CPU_UTIL]="%"
	[CPU_IOWAIT]="%"
	[CPU_STEAL]="%"
	[CPU_SYSTEM]="%"
	[CPU_SOFTIRQ]="%"
	[CPU_CTXT]=""
	[SERV_TCP_LISTEN]=""
	[CLIENT_TCP_ESTABL]=""
	[CLIENT_TCP_USED]="%"
	[CLIENT_TCP_DROP]="pkt"
	[CLIENT_TCP_TIME_WAIT]=""
	[CLIENT_TCP_CLOSE_WAIT]=""
	[NET_SOCKET_COUNT]=""
	[UDP_RCVBUF_ERR]="pkt"
	[UDP_SNDBUF_ERR]="pkt"
	[UDP_IN_ERRORS]="pkt"
	[AWG_RSS]="KB"
	[AWG_FD_COUNT]=""
	[AWG_FD_LIMIT]=""
	[AWG_CPU]="%"
	[AWG_THREAD]=""
	[AWG_RESTARTS]=""
)

function get_TIME_BASED_METRICS {
    local param1=$1 metric1=$2 division="${4:-"1"}"
    local -n out_delta=$3
    if [[ -z ${PREVIOUS_VALUES["$metric1"]} ]]; then
            PREVIOUS_VALUES["$metric1"]=$param1
            return 1
    fi
    out_delta=$(awk -v p1="$param1" -v p2="${PREVIOUS_VALUES["$metric1"]}" -v p3="$division" 'BEGIN {print (p1 - p2) / p3 }')
    PREVIOUS_VALUES["$metric1"]=$param1
    return 0
}