ARG ARCH=
FROM ${ARCH}alpine:3.22

ENV CRON_TIME="0 */12 * * *"
ENV UID=100
ENV GID=100
ENV DELETE_AFTER=0
ENV BACKUP_ENCRYPTION_KEY=""
ENV TG_TOKEN=""
ENV TG_CHAT_ID=""
ENV VWDUMP_DEBUG="false"
ENV DISABLE_WARNINGS="false"
ENV DISABLE_TELEGRAM_UPLOAD="false"
ENV PBKDF2_ITERATIONS=600000

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY script.sh /app/script.sh

RUN addgroup -S app && adduser -S -G app app \
    && apk add --no-cache \
        busybox-suid \
        su-exec \
        xz \
        tzdata \
        openssl \
        curl \
        sqlite \
    && mkdir -p /app/log/ \
    && chown -R app:app /app \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && chmod +x /app/script.sh

ENTRYPOINT ["entrypoint.sh"]