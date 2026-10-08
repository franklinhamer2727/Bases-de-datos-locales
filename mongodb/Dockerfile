# MongoDB 8.0 + scripts de inicializacion horneados en la imagen.
ARG MONGO_IMAGE=mongo:8.0
FROM ${MONGO_IMAGE}

COPY init/ /docker-entrypoint-initdb.d/
RUN find /docker-entrypoint-initdb.d -type f -exec sed -i 's/\r$//' {} +

EXPOSE 27017
