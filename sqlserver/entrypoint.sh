#!/usr/bin/env bash
# Arranca SQL Server y deja garantizado, en CADA arranque:
#   1. que 'sa' entra con MSSQL_SA_PASSWORD del .env (si el volumen se creo con
#      otra password, la restablece);
#   2. que la base APP_DB, el login APP_USER y su usuario mapeado existen y el
#      login funciona (si no, el contenedor NO queda "healthy" y lo dice en el log).
set -euo pipefail

: "${MSSQL_SA_PASSWORD:?falta MSSQL_SA_PASSWORD}"
: "${APP_PASSWORD:?falta APP_PASSWORD}"
: "${APP_DB:=GNBPE_DATAHUB}"
: "${APP_USER:=datahub}"
: "${INIT_TIMEOUT:=240}"

INIT_DIR=/usr/src/init
READY_FLAG=/tmp/mssql-init.done
ERRORLOG=/var/opt/mssql/log/errorlog
START_MARK=/tmp/mssql-start.mark
rm -f "$READY_FLAG"

log() { echo "[init] $*"; }
die() {
    echo "[init] ERROR: $*" >&2
    [ -n "${MOTOR:-}" ] && kill -TERM "$MOTOR" 2>/dev/null || true
    exit 1
}

# --- Validaciones previas ---------------------------------------------------
check_password() {
    local name="$1" pw="$2" groups=0
    [ "${#pw}" -ge 8 ] || die "$name debe tener al menos 8 caracteres."
    [[ "$pw" =~ [A-Z] ]] && groups=$((groups+1))
    [[ "$pw" =~ [a-z] ]] && groups=$((groups+1))
    [[ "$pw" =~ [0-9] ]] && groups=$((groups+1))
    [[ "$pw" =~ [^A-Za-z0-9] ]] && groups=$((groups+1))
    [ "$groups" -ge 3 ] || die "$name debe combinar 3 de 4: mayuscula, minuscula, digito, simbolo."
    [[ "$pw" != *"'"* ]] || die "$name no puede contener comilla simple (')."
    [[ "$pw" != *'$'* ]] || die "$name no puede contener '\$'."
}
check_password MSSQL_SA_PASSWORD "$MSSQL_SA_PASSWORD"
check_password APP_PASSWORD "$APP_PASSWORD"

ident='^[A-Za-z_][A-Za-z0-9_]{0,127}$'
[[ "$APP_DB"   =~ $ident ]] || die "APP_DB='$APP_DB' no es un identificador valido."
[[ "$APP_USER" =~ $ident ]] || die "APP_USER='$APP_USER' no es un identificador valido."
[ "${APP_USER,,}" != "sa" ] || die "APP_USER no puede ser 'sa'."
# La politica de SQL Server rechaza passwords que contienen el nombre del login
# (sin distinguir mayusculas): "DataHub_2026" no sirve para el usuario "datahub".
if [ "${#APP_USER}" -gt 2 ] && [[ "${APP_PASSWORD,,}" == *"${APP_USER,,}"* ]]; then
    die "APP_PASSWORD no puede contener el nombre del usuario ('$APP_USER'); SQL Server la rechaza por politica."
fi

if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
    SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C)
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
    SQLCMD=(/opt/mssql-tools/bin/sqlcmd)
else
    die "no se encontro sqlcmd en la imagen."
fi
sa_sql()  { "${SQLCMD[@]}" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -l 5 "$@"; }
app_sql() { "${SQLCMD[@]}" -S localhost -U "$APP_USER" -P "$APP_PASSWORD" -d "$APP_DB" -l 5 "$@"; }

# --- Motor ------------------------------------------------------------------
MOTOR=""
start_engine() {
    touch "$START_MARK"
    /opt/mssql/bin/sqlservr &
    MOTOR=$!
}
stop_engine() {
    [ -n "$MOTOR" ] || return 0
    kill -TERM "$MOTOR" 2>/dev/null || true
    wait "$MOTOR" 2>/dev/null || true
    MOTOR=""
}
shutdown() { log "senal recibida, deteniendo SQL Server..."; stop_engine; exit 0; }
trap shutdown TERM INT

# Devuelve 0 = sa entra; 2 = el motor responde pero la password de sa no coincide.
wait_for_sa() {
    local i
    for i in $(seq 1 $((INIT_TIMEOUT / 2))); do
        kill -0 "$MOTOR" 2>/dev/null || die "sqlservr termino durante el arranque; revise el log de arriba."
        # Listo = sa entra Y ninguna base sigue en recuperacion/arranque.
        # (sa puede entrar antes de que las bases de usuario esten ONLINE; si
        # se ejecuta el init en ese momento falla con "Msg 904 ... cannot be
        # autostarted during server shutdown or startup".)
        local pend
        if pend=$(sa_sql -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE state_desc NOT IN ('ONLINE','OFFLINE')" 2>/dev/null) \
           && [ "$(echo "$pend" | tr -d '[:space:]')" = "0" ]; then
            return 0
        fi
        # Solo se mira el errorlog de ESTE arranque (mas nuevo que la marca), y
        # solo el motivo exacto: durante el arranque hay otros "Login failed"
        # (p.ej. "script upgrade mode") que NO son de password.
        if [ "$ERRORLOG" -nt "$START_MARK" ] \
           && grep -aq "Login failed for user 'sa'. Reason: Password did not match" "$ERRORLOG"; then
            return 2
        fi
        sleep 2
    done
    die "el motor no acepto conexiones en ${INIT_TIMEOUT}s. Revise memoria de Docker/WSL (SQL Server necesita 2 GB libres)."
}

start_engine
log "esperando a que el motor acepte conexiones (max ${INIT_TIMEOUT}s)..."
set +e; wait_for_sa; rc=$?; set -e

if [ "$rc" = "2" ]; then
    # El volumen ya existia y se creo con OTRA password de sa (MSSQL_SA_PASSWORD
    # solo se aplica al crear el volumen). Se restablece a la del .env.
    log "la password de 'sa' del volumen no coincide con MSSQL_SA_PASSWORD; restableciendola..."
    stop_engine
    if ! MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD" timeout 180 /opt/mssql/bin/mssql-conf -n set-sa-password </dev/null; then
        die "no se pudo restablecer la password de 'sa'. Opciones: (1) poner en .env la password con la que se creo el volumen, o (2) 'docker compose down -v' (BORRA los datos) y volver a levantar."
    fi
    start_engine
    set +e; wait_for_sa; rc=$?; set -e
    [ "$rc" = "0" ] || die "'sa' sigue sin entrar despues de restablecer la password."
    log "password de 'sa' restablecida."
fi
log "motor listo; 'sa' entra con la password del .env."

# --- Scripts de inicializacion (orden alfabetico, idempotentes) --------------
shopt -s nullglob
# Se reintenta: justo despues del arranque SQL Server aun puede devolver
# errores transitorios. Los scripts son idempotentes, repetirlos es seguro.
for f in "$INIT_DIR"/*.sql; do
    name="$(basename "$f")"
    ok=0
    for intento in 1 2 3 4 5 6 7 8 9 10; do
        log "ejecutando $name (intento $intento)"
        if out=$(sa_sql -b -I \
                 -v APP_DB="$APP_DB" APP_USER="$APP_USER" APP_PASSWORD="$APP_PASSWORD" \
                 -i "$f" 2>&1); then
            [ -n "$out" ] && echo "$out"
            ok=1; break
        fi
        echo "$out"
        kill -0 "$MOTOR" 2>/dev/null || die "sqlservr termino mientras se ejecutaba $name."
        sleep 5
    done
    [ "$ok" = "1" ] || die "fallo $name tras 10 intentos (ver mensaje de SQL Server arriba)"
done

# --- Verificacion final: el usuario de la app entra de verdad ----------------
if ! out=$(app_sql -b -h -1 -W -Q "SET NOCOUNT ON; SELECT SUSER_NAME() + ' @ ' + DB_NAME()" 2>&1); then
    die "el login '$APP_USER' no puede entrar a '$APP_DB': $out"
fi
log "verificado: $(echo "$out" | head -1)"

touch "$READY_FLAG"
log "LISTO. sa y '$APP_USER' (base '$APP_DB') aceptan conexiones en el puerto 1433 del contenedor."

wait "$MOTOR"
