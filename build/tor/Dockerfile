FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
# netcat is only used by the compose healthcheck
RUN apk add --no-cache tor netcat-openbsd
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh
# chown to tor:tor — the GROUP matters: the bitcoin container joins gid 101
# to read the control-auth cookie for the inbound onion service
RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/tor && chown -R tor:tor /var/lib/tor
USER tor
ENTRYPOINT ["/entrypoint.sh"]
