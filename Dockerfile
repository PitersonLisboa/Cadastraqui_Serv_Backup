FROM alpine:3.19

# Instala PostgreSQL client, curl e supercronic (cron leve para containers)
RUN apk add --no-cache \
    postgresql16-client \
    curl \
    bash \
    gzip \
    python3 \
    tzdata

# Configura timezone para Brasília
ENV TZ=America/Sao_Paulo
RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime

# Instala supercronic (cron otimizado para containers Docker)
ARG SUPERCRONIC_VERSION=v0.2.29
ARG SUPERCRONIC_SHA1SUM=cd48d45c4b10f3f0bfdd3a57d054cd05ac96812b
RUN curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    -o /usr/local/bin/supercronic \
    && echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - \
    && chmod +x /usr/local/bin/supercronic

WORKDIR /app

# Copia scripts
COPY backup.sh /app/backup.sh
COPY crontab /app/crontab

RUN chmod +x /app/backup.sh

# Executa supercronic com o crontab
CMD ["supercronic", "/app/crontab"]
