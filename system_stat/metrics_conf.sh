#!/bin/bash

INF=100000000000

# ВНИМАНИЕ: раньше тут были захардкожены реальные BOT_TOKEN/CHAT_ID — этот секрет уже засвечен
# (в истории редактирования и в переписке), его стоит отозвать/пересоздать через @BotFather.
# Теперь токен и chat_id читаются из окружения — прокидывайте их через
# `-e BOT_TOKEN=... -e CHAT_ID=...` в docker run (rebuild.sh), а не храните в самом файле.
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"

declare -A LAST_TTIME # время последнего алерта по метрике (для cooldown)

declare METRICS=(
	CPU_LOAD5         # Средняя загрузка за 5 мин — сглаженный индикатор, есть ли очередь на CPU. Растёт быстрее, чем CPU_UTIL реагирует, и учитывает процессы в D-state (I/O wait)
	MEM_USED_PCT      # % использованной RAM — прямой предиктор OOM. Для прокси критично: при нехватке памяти ядро начнёт убивать процессы, включая сам прокси
	SWAP_USED_PCT     # % использованного swap — если swap активно растёт, машина уже под давлением. При свопе latency прокси улетает в космос, т.к. страницы читаются с диска
	MEM_OOM_COUNT     # Счётчик срабатываний OOM-killer — counter, важен rate. Один тик = кто-то умер; если это прокси, клиенты уже получили 502. Самый жёсткий memory-алерт
	CPU_CTXT          # Переключений контекста — counter, важен rate/sec. Аномально высокий = thrashing scheduler'а (много коротких процессов/потоков), растёт latency
	DISK_ROOT_PCT     # % занятого места на /. Диск в 100% роняет логи, сокеты-файлы, PID-файлы — прокси не сможет писать, а под нагрузкой и принимать коннекты
	DISK_INODE_PCT    # % использованных inode на /. Inode кончаются раньше места при миллионах мелких файлов (логи, кеш, сессии). Прокси теряет возможность создавать сокеты/логи, хотя df показывает свободное место
	DISK_IO_UTIL_PCT  # % времени, когда диск был занят хоть одной операцией. Counter-based (io_ticks из /proc/diskstats). При 100% — очередь растёт, latency улетает, iowait шумит. Прямой индикатор «диск — узкое место»
	PROC_COUNT        # Общее число процессов. Резкий рост = fork-бомба, утечка воркеров, зомби-накопление. Стабильный рост — медленный утечка-баг в приложении
	PROC_ZOMBI_COUNT  # Число зомби-процессов. Рост = родительский процесс не делает wait() за детьми — на маленькой системе с 1GB RAM это быстро съедает таблицу процессов/PID
	PROC_BLOCKED      # Процессы в состоянии D (uninterruptible sleep, обычно диск/сеть-storage). Устойчивый рост = диск/сеть не успевает отвечать, процессы «зависают»
	PROC_TOTAL_THREADS   # Суммарное число тредов в системе (из /proc/loadavg). На маленькой машине рост треда-каунта = утечка потоков/воркеров, съедающая и так дефицитную RAM
	PROC_RUNNING_THREADS # Число тредов в состоянии running/runnable прямо сейчас (из /proc/loadavg). При 1 vCPU это фактически очередь на единственное ядро
	FORKS_PER_SEC     # Число fork() в секунду — counter, важен rate. Резкий скачок = fork-бомба или патологическое поведение сервиса (respawn-loop).                # ВАЖНО: сам этот скрипт форкает много subprocess'ов (ps/ss/df/awk/conntrack) каждую итерацию — учитывайте это в baseline, порог ниже уже подобран с запасом на самонагрузку
	FD_USED           # Использовано файловых дескрипторов системой (/proc/sys/fs/file-nr, kernel-режим, общесистемно). Приближение к fs.file-max = EMFILE, отказы новых соединений
	CPU_UTIL          # Суммарная загрузка CPU в % — общий индикатор «дыхания» системы. Именно её обычно смотрят первым при деградации
	CPU_STEAL         # Время, украденное гипервизором — на VPS показывает шумных соседей. Если >5–10%, твоя машина тормозит не из-за твоего кода, и тюнить локально бесполезно
	CPU_SOFTIRQ       # Обработка softirq (в основном сеть, NET_RX/TX). Для прокси — прямой индикатор: если softirq высокий, ядро не успевает обрабатывать пакеты, растут drops и retrans
	CPU_SYSTEM        # Время в kernel space. Растёт при syscall-штормах, высоком network I/O, мьютексах. Для прокси часто важнее user time — узкое место в ядре, а не в коде
	CPU_IOWAIT        # % времени CPU в ожидании завершения I/O. На 1 vCPU это напрямую "съедает" единственное ядро — высокий iowait = диск тормозит весь процесс, а не только его собственный I/O
	SERV_TCP_LISTEN   # Сокеты в LISTEN — сколько портов/бэкендов слушается. conntrack не видит LISTEN, поэтому берём из ss. Если число внезапно упало — кто-то из воркеров отвалился и не переподнялся
	NET_RX_BYTES      # Принято байт по сети — counter, важен rate. Показывает входящий трафик; резкий рост/падение помогает понять, идёт ли нагрузка вообще
	NET_TR_BYTES      # Передано байт по сети — counter, важен rate. Показывает исходящий трафик; вместе с NET_RX_BYTES даёт картину сетевой активности
	NET_RX_DROPPED    # Входящие пакеты, отброшенные ядром — counter, важен rate. Растёт при переполнении буферов/очередей NIC: пакеты не доходят до прокси, клиенты видят таймауты
	NET_TR_DROPPED    # Исходящие пакеты, отброшенные ядром — counter, важен rate. Растёт при переполнении TX-очередей: ответы не уходят, соединения зависают в retrans
	CLIENT_TCP_ESTABL     # Число TCP-соединений в ESTABLISHED в conntrack — включая транзит клиентов VPN и локальные соединения сервера. Главная метрика нагрузки
	CLIENT_TCP_USED       # % заполнения таблицы conntrack (nf_conntrack_count / nf_conntrack_max). Приближение к 100% = новые соединения начнут дропаться
	CLIENT_TCP_DROP       # Counter пакетов, отброшенных conntrack из-за переполнения таблицы. Rate > 0 = клиенты уже теряют соединения
	CLIENT_TCP_TIME_WAIT  # TCP-соединения в TIME_WAIT в conntrack. Накопление = много коротких соединений через сервер
	CLIENT_TCP_CLOSE_WAIT # TCP-соединения в CLOSE_WAIT в conntrack. Устойчивый рост = FD-leak
	NET_SOCKET_COUNT  # Всего сокетов в системе (TCP+UDP+UNIX). Резкий рост = утечка сокетов, приближение к fs.file-max. Ключевой индикатор исчерпания FD
	UDP_RCVBUF_ERR    # Пакеты, отброшенные ядром: буфер приёма UDP-сокета полон — counter, важен rate. Для VPN с играми/видео — прямой индикатор потерь внутри туннеля
	UDP_SNDBUF_ERR    # Пакеты, отброшенные ядром: буфер отправки UDP-сокета полон — counter, важен rate. Аналогично RCVBUF, но на исходящем направлении
	UDP_IN_ERRORS     # Ошибки входящих UDP-пакетов (кроме checksum) — counter, важен rate. Битые пакеты, проблемы на L2/L3, редко, но полезно при диагностике
)

declare AWG_METRICS=(
	AWG_RSS
	AWG_FD_COUNT
	AWG_FD_LIMIT
	AWG_CPU
	AWG_THREAD
	#AWG_RESTARTS
)

declare -A AWG_METRICS_FORMAT=(
	[AWG_RSS]="int"
	[AWG_FD_COUNT]="int"
	[AWG_FD_LIMIT]="float"
	[AWG_CPU]="float"
	[AWG_THREAD]="int"
	#[AWG_RESTARTS]="int"
)

IS_ONCE=0

# TODO: PATH_TO_CONFIG_FILE и весь --config механизм в system_stat.sh — мёртвый код после перехода
# на прямое редактирование этого файла. Выпилить вместе с apply_config_from_file при следующей чистке.
PATH_TO_CONFIG_FILE=""

# ============================================================
# ПОРОГИ ПОДОБРАНЫ ПОД: 1 vCPU / 1 GB RAM / 10 GB Disk (небольшой VPN-прокси на Amnezia).
# Для NET_RX_BYTES / NET_TR_BYTES реальная пропускная способность канала неизвестна —
# взято консервативное допущение ~80 Мбит/с (10 МБ/с); подставьте свой реальный лимит канала.
# Для counter-метрик, которые в норме равны 0 (drops/errors/oom), порог сознательно НЕ 0,
# а >=1 — иначе из-за сравнения "value >= threshold" алерт будет срабатывать постоянно.
# ============================================================
declare -A OPTIONS=(
	[NET_RX_BYTES]=10000000
	[NET_TR_BYTES]=10000000
	[NET_RX_DROPPED]=1
	[NET_TR_DROPPED]=1
	[VPN_INT]=""
	[CPU_LOAD5]=1.5
	[MEM_USED_PCT]=85
	[SWAP_USED_PCT]=50
	[SWAP_USED_BYTES]=0
	[MEM_OOM_COUNT]=1
	[DISK_ROOT_PCT]=85
	[DISK_INODE_PCT]=85
	[DISK_IO_UTIL_PCT]=80
	[PROC_COUNT]=300
	[PROC_ZOMBI_COUNT]=5
	[PROC_BLOCKED]=3
	[PROC_TOTAL_THREADS]=500
	[PROC_RUNNING_THREADS]=4
	[FORKS_PER_SEC]=300  # восстановлено с 50: см. комментарий у метрики выше — 50 ловит собственную форк-нагрузку скрипта, а не реальные аномалии
	[FD_USED]=50000
	[UPDATE_TIME]=5
	[COOLDOWN]=300  # восстановлено с 6: при UPDATE_TIME=5 и COOLDOWN=6 алерт будет дублироваться почти каждую итерацию — если это осознанный выбор, верните 6 обратно
	[CPU_UTIL]=90
	[CPU_IOWAIT]=20
	[CPU_STEAL]=10
	[CPU_SYSTEM]=40
	[CPU_SOFTIRQ]=30
	[CPU_CTXT]=20000
	[SERV_TCP_LISTEN]=20
	[CLIENT_TCP_ESTABL]=2000
	[CLIENT_TCP_USED]=80
	[CLIENT_TCP_DROP]=1
	[CLIENT_TCP_TIME_WAIT]=1000
	[CLIENT_TCP_CLOSE_WAIT]=50
	[NET_SOCKET_COUNT]=5000
	[UDP_RCVBUF_ERR]=1
	[UDP_SNDBUF_ERR]=1
	[UDP_IN_ERRORS]=1
	[AWG_RSS]=150000
	[AWG_FD_COUNT]=500
	[AWG_FD_LIMIT]=80
	[AWG_CPU]=80
	[AWG_THREAD]=50
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
	[SWAP_USED_BYTES]="int"
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
	[FD_USED]="int"
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
	[SWAP_USED_BYTES]=0
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
	[FD_USED]=0
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
	[SWAP_USED_BYTES]=$INF
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
	[FD_USED]=$INF
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

# Единицы измерения — только для форматирования вывода (once, alert), не участвуют в валидации
declare -A UNIT=(
	[NET_RX_BYTES]="B"
	[NET_TR_BYTES]="B"
	[NET_RX_DROPPED]="pkt"
	[NET_TR_DROPPED]="pkt"
	[CPU_LOAD5]=""
	[MEM_USED_PCT]="%"
	[SWAP_USED_PCT]="%"
	[SWAP_USED_BYTES]="B"
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
	[FD_USED]=""
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