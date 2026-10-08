# Imagen SQL Server 2022 + sqlcmd + inicializacion idempotente (BD + login app).
# Se puede fijar un CU concreto con:  docker compose build --build-arg MSSQL_IMAGE=mcr.microsoft.com/mssql/server:2022-CU16-ubuntu-22.04
ARG MSSQL_IMAGE=mcr.microsoft.com/mssql/server:2022-latest
FROM ${MSSQL_IMAGE}

USER root

# Las imagenes 2022 recientes ya traen /opt/mssql-tools18. Solo se instala si
# falta: el build no depende de la red de Microsoft cuando no hace falta.
RUN if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then \
        echo "sqlcmd (tools18) ya viene en la imagen"; \
    else \
        apt-get update \
     && apt-get install -y --no-install-recommends curl gnupg ca-certificates apt-transport-https \
     && . /etc/os-release \
     && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
          | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
     && curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/prod.list" \
          | sed 's|^deb |deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg] |' \
          > /etc/apt/sources.list.d/mssql-release.list \
     && apt-get update \
     && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 unixodbc \
     && rm -rf /var/lib/apt/lists/*; \
    fi

ENV PATH="/opt/mssql-tools18/bin:${PATH}"

COPY init/ /usr/src/init/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY verificar.sh /usr/local/bin/verificar.sh

# Quitar CRLF: si el repo se clona en Windows con autocrlf, un entrypoint con
# \r\n falla con "no such file or directory" (el shebang queda "bash\r").
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh /usr/local/bin/verificar.sh /usr/src/init/*.sql \
 && chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/verificar.sh \
 && chown -R mssql:root /usr/src/init

# La imagen corre como 'mssql' (uid 10001), no como root.
USER mssql
EXPOSE 1433
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
