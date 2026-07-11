FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
# netcat is only used by the compose healthcheck
RUN apk add --no-cache tor netcat-openbsd
COPY torrc /etc/tor/torrc
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor
USER tor
ENTRYPOINT ["tor"]
CMD ["-f", "/etc/tor/torrc"]
