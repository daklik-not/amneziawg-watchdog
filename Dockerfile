FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    coreutils \
    procps-ng \
    iproute2 \
    conntrack-tools \
    gawk \
    grep \
    curl \
    sed

WORKDIR /opt/system_stat

# Copy the system_stat/ folder from the host into the container WORKDIR
COPY system_stat/ /opt/system_stat/

RUN chmod +x /opt/system_stat/system_stat.sh

ENV ROOT_PATH=/host

ENTRYPOINT ["/opt/system_stat/system_stat.sh"]
