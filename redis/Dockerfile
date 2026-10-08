# Redis 8 + redis.conf horneado (montado desde Windows llega con CRLF/permisos raros).
ARG REDIS_IMAGE=redis:8-alpine
FROM ${REDIS_IMAGE}

COPY conf/redis.conf /usr/local/etc/redis/redis.conf
RUN sed -i 's/\r$//' /usr/local/etc/redis/redis.conf \
 && chmod 0644 /usr/local/etc/redis/redis.conf

EXPOSE 6379
CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
