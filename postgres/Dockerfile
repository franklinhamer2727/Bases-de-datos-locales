# PostgreSQL + scripts de inicializacion horneados en la imagen.
# Version fija por defecto; se puede cambiar con --build-arg PG_IMAGE=postgres:17.x
ARG PG_IMAGE=postgres:17-bookworm
FROM ${PG_IMAGE}

COPY init/ /docker-entrypoint-initdb.d/

# Quitar CRLF: un .sh con \r\n (repo clonado en Windows con autocrlf) falla
# con errores raros como "$'\r': command not found".
RUN sed -i 's/\r$//' /docker-entrypoint-initdb.d/* \
 && chmod 0755 /docker-entrypoint-initdb.d/*.sh

EXPOSE 5432
