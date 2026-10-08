#!/usr/bin/env bash
# Verifica que sa y el usuario de la app entren. Uso:
#   docker exec sqlserver-dev verificar.sh                 (dentro del contenedor)
#   docker exec sqlserver-dev verificar.sh host.docker.internal 1433
#        (entrando por el puerto publicado en Windows, igual que DBeaver)
set -u
HOST="${1:-localhost}"; PORT="${2:-1433}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
fallos=0
probar() { # etiqueta usuario password base
    local out
    if out=$("$SQLCMD" -C -b -l 10 -S "$HOST,$PORT" -U "$2" -P "$3" -d "$4" -h -1 -W \
             -Q "SET NOCOUNT ON; SELECT SUSER_NAME() + ' en ' + DB_NAME() + ' (' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) + ')'" 2>&1); then
        echo "[OK]    $1 -> $(echo "$out" | head -1)"
    else
        echo "[ERROR] $1 -> $(echo "$out" | tr '\n' ' ')"; fallos=$((fallos+1))
    fi
}
echo "Probando $HOST:$PORT"
probar "sa"        sa          "$MSSQL_SA_PASSWORD" master
probar "$APP_USER" "$APP_USER" "$APP_PASSWORD"      "$APP_DB"
exit "$fallos"
