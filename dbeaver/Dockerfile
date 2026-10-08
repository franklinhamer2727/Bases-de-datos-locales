# CloudBeaver CE (DBeaver web) con las conexiones locales precargadas.
ARG CB_IMAGE=dbeaver/cloudbeaver:latest
FROM ${CB_IMAGE}

# En el PRIMER arranque (workspace vacio) el script oficial
# run-cloudbeaver-server.sh copia conf/initial-data-sources.conf a
# workspace/GlobalConfiguration/.dbeaver/data-sources.json.
COPY conf/conexiones.json /opt/cloudbeaver/conf/initial-data-sources.conf
RUN sed -i 's/\r$//' /opt/cloudbeaver/conf/initial-data-sources.conf \
 && chmod 0644 /opt/cloudbeaver/conf/initial-data-sources.conf

EXPOSE 8978
