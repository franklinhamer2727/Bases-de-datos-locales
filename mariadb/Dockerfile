# MariaDB 11.4 LTS + configuracion e init horneados en la imagen.
ARG MARIADB_IMAGE=mariadb:11.4
FROM ${MARIADB_IMAGE}

# Copiado, no montado: desde Windows el .cnf llega con permisos 777 y se ignora.
COPY conf/datahub.cnf /etc/mysql/conf.d/datahub.cnf
COPY init/ /docker-entrypoint-initdb.d/
RUN sed -i 's/\r$//' /etc/mysql/conf.d/datahub.cnf \
 && find /docker-entrypoint-initdb.d -type f \( -name '*.sh' -o -name '*.sql' \) -exec sed -i 's/\r$//' {} + \
 && chmod 0644 /etc/mysql/conf.d/datahub.cnf

EXPOSE 3306
