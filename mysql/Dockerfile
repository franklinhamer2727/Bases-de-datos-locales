# MySQL 8.4 LTS + configuracion e init horneados en la imagen.
ARG MYSQL_IMAGE=mysql:8.4
FROM ${MYSQL_IMAGE}

# El .cnf se copia (no se monta): en un bind mount de Windows el archivo
# aparece con permisos 777 y MySQL lo IGNORA ("World-writable config file").
COPY conf/datahub.cnf /etc/mysql/conf.d/datahub.cnf
COPY init/ /docker-entrypoint-initdb.d/
RUN sed -i 's/\r$//' /etc/mysql/conf.d/datahub.cnf \
 && find /docker-entrypoint-initdb.d -type f \( -name '*.sh' -o -name '*.sql' \) -exec sed -i 's/\r$//' {} + \
 && chmod 0644 /etc/mysql/conf.d/datahub.cnf

EXPOSE 3306
