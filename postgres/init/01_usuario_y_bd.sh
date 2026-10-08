#!/usr/bin/env bash
# Crea el rol y la base de la aplicacion. La imagen oficial ejecuta
# /docker-entrypoint-initdb.d/* SOLO cuando el volumen de datos esta vacio
# (primer arranque). Aun asi el script es idempotente.
#
# NO se usa el superusuario 'postgres' desde Airflow/ETL: el rol de la app es
# dueno de SU base y nada mas (sin SUPERUSER, CREATEDB ni CREATEROLE).
set -euo pipefail

: "${APP_DB:?falta APP_DB}"
: "${APP_USER:?falta APP_USER}"
: "${APP_PASSWORD:?falta APP_PASSWORD}"

echo "[init] creando rol '$APP_USER' y base '$APP_DB'"

# format(%I, %L) cita identificadores y literales: no hay inyeccion ni
# problemas con comillas en la password.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_db="$APP_DB" -v app_user="$APP_USER" -v app_password="$APP_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' TEMPLATE template0', :'app_db', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') \gexec

-- Nadie mas que el dueno se conecta a la base de la app.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'app_db') \gexec
SELECT format('GRANT ALL ON DATABASE %I TO %I', :'app_db', :'app_user') \gexec

\connect :"app_db"

-- Desde PG15 'public' ya no es escribible por todos; se le da al rol de la app.
SELECT format('ALTER SCHEMA public OWNER TO %I', :'app_user') \gexec
SQL

echo "[init] listo: $APP_USER@$APP_DB"
