FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
# netcat is only used by the compose healthcheck
RUN apk add --no-cache tor netcat-openbsd
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh
# chown to tor:tor — the GROUP matters: the bitcoin container joins gid 101
# to read the control-auth cookie for the inbound onion service
RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/tor && chown -R tor:tor /var/lib/tor
USER tor
ENTRYPOINT ["/entrypoint.sh"]
