#!/usr/bin/env bash
# Arranca SQL Server, espera a que acepte conexiones y ejecuta, en orden,
# todos los init/*.sql (idempotentes). Al terminar deja una marca que usa el
# healthcheck: "healthy" significa motor arriba Y base/login creados.
set -euo pipefail

: "${MSSQL_SA_PASSWORD:?falta MSSQL_SA_PASSWORD}"
: "${APP_PASSWORD:?falta APP_PASSWORD}"
: "${APP_DB:=GNBPE_DATAHUB}"
: "${APP_USER:=datahub}"
: "${INIT_TIMEOUT:=180}"

INIT_DIR=/usr/src/init
READY_FLAG=/tmp/mssql-init.done
rm -f "$READY_FLAG"

log() { echo "[init] $*"; }
die() { echo "[init] ERROR: $*" >&2; exit 1; }

# --- Validaciones previas: fallar rapido y con un mensaje claro -------------
# La politica de SQL Server: 8+ caracteres y 3 de 4 grupos. Si no se cumple,
# el motor se apaga con un mensaje que se pierde en el log.
check_password() {
    local name="$1" pw="$2" groups=0
    [ "${#pw}" -ge 8 ] || die "$name debe tener al menos 8 caracteres."
    [[ "$pw" =~ [A-Z] ]] && groups=$((groups+1))
    [[ "$pw" =~ [a-z] ]] && groups=$((groups+1))
    [[ "$pw" =~ [0-9] ]] && groups=$((groups+1))
    [[ "$pw" =~ [^A-Za-z0-9] ]] && groups=$((groups+1))
    [ "$groups" -ge 3 ] || die "$name debe combinar 3 de 4: mayuscula, minuscula, digito, simbolo."
    # Se inyecta dentro de '...' en T-SQL: una comilla simple romperia el script.
    [[ "$pw" != *"'"* ]] || die "$name no puede contener comilla simple (')."
}
check_password MSSQL_SA_PASSWORD "$MSSQL_SA_PASSWORD"
check_password APP_PASSWORD "$APP_PASSWORD"

ident='^[A-Za-z_][A-Za-z0-9_]{0,127}$'
[[ "$APP_DB"   =~ $ident ]] || die "APP_DB='$APP_DB' no es un identificador valido (letras, digitos, _)."
[[ "$APP_USER" =~ $ident ]] || die "APP_USER='$APP_USER' no es un identificador valido (letras, digitos, _)."

# tools18 cifra por defecto: -C confia en el certificado autofirmado.
if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
    SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C)
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
    SQLCMD=(/opt/mssql-tools/bin/sqlcmd)
else
    die "no se encontro sqlcmd en la imagen."
fi
sa_sql() { "${SQLCMD[@]}" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" "$@"; }

# --- Motor ------------------------------------------------------------------
/opt/mssql/bin/sqlservr &
MOTOR=$!

shutdown() {
    log "senal recibida, deteniendo SQL Server..."
    kill -TERM "$MOTOR" 2>/dev/null || true
    wait "$MOTOR" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

log "esperando a que el motor acepte conexiones (max ${INIT_TIMEOUT}s)..."
listo=0
for _ in $(seq 1 $((INIT_TIMEOUT / 2))); do
    # Si el motor murio (p.ej. password rechazada), no tiene sentido esperar.
    kill -0 "$MOTOR" 2>/dev/null || die "sqlservr termino durante el arranque; revise el log de arriba."
    if sa_sql -Q "SET NOCOUNT ON; SELECT 1" -l 2 >/dev/null 2>&1; then
        listo=1; break
    fi
    sleep 2
done

if [ "$listo" != "1" ]; then
    kill -TERM "$MOTOR" 2>/dev/null || true
    die "el motor no acepto conexiones en ${INIT_TIMEOUT}s. Si es el primer arranque, revise memoria asignada a Docker/WSL (minimo 2 GB)."
fi
log "motor listo."

# --- Scripts de inicializacion (orden alfabetico, todos idempotentes) --------
shopt -s nullglob
for f in "$INIT_DIR"/*.sql; do
    log "ejecutando $(basename "$f")"
    sa_sql -b -I \
        -v APP_DB="$APP_DB" APP_USER="$APP_USER" APP_PASSWORD="$APP_PASSWORD" \
        -i "$f" \
        || { kill -TERM "$MOTOR" 2>/dev/null || true; die "fallo $(basename "$f")"; }
done

touch "$READY_FLAG"
log "base '$APP_DB' y login '$APP_USER' listos. Conecte en el puerto 1433."

wait "$MOTOR"
