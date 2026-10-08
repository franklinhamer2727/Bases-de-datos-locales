# Contenedor de utilidades SQLite: crea la base y aplica init/*.sql.
ARG ALPINE_IMAGE=alpine:3.20
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache sqlite bash tzdata

COPY init/ /usr/src/init/
COPY migrar.sh /usr/local/bin/migrar.sh
RUN sed -i 's/\r$//' /usr/local/bin/migrar.sh \
 && chmod 0755 /usr/local/bin/migrar.sh

WORKDIR /data
ENTRYPOINT ["/usr/local/bin/migrar.sh"]
