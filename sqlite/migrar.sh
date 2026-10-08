#!/usr/bin/env bash
# Crea la base SQLite (si no existe) y aplica init/*.sql UNA sola vez cada uno,
# en orden alfabetico, registrandolos en la tabla _migraciones.
# Con argumentos ejecuta ese comando en su lugar, p.ej.:
#   docker compose run --rm sqlite sqlite3 /data/datahub.db
set -euo pipefail

if [ "$#" -gt 0 ]; then exec "$@"; fi

DATA_DIR="${DATA_DIR:-/data}"
INIT_DIR="${INIT_DIR:-/usr/src/init}"
DB="$DATA_DIR/${SQLITE_DB:-datahub.db}"

log() { echo "[sqlite] $*"; }
die() { echo "[sqlite] ERROR: $*" >&2; exit 1; }

mkdir -p "$DATA_DIR"
[ -f "$DB" ] && log "usando base existente $DB" || log "creando $DB"

# journal_mode=DELETE (no WAL): WAL usa memoria compartida que no funciona
# bien sobre carpetas de Windows montadas en Docker.
sqlite3 -bail "$DB" <<'SQL' >/dev/null
PRAGMA journal_mode = DELETE;
CREATE TABLE IF NOT EXISTS _migraciones (
    archivo     TEXT PRIMARY KEY,
    sha256      TEXT NOT NULL,
    aplicado_en TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
SQL

aplicados=0
shopt -s nullglob
for f in "$INIT_DIR"/*.sql; do
    name="$(basename "$f")"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "nombre de archivo no permitido: $name"
    sum="$(sed 's/\r$//' "$f" | sha256sum | cut -d' ' -f1)"
    prev="$(sqlite3 "$DB" "SELECT sha256 FROM _migraciones WHERE archivo = '$name';")"

    if [ -z "$prev" ]; then
        log "aplicando $name"
        # Todo el script + su registro en una sola transaccion: o entra completo o nada.
        { echo "PRAGMA foreign_keys = ON;"; echo "BEGIN;"; sed 's/\r$//' "$f"; echo;
          echo "INSERT INTO _migraciones (archivo, sha256) VALUES ('$name', '$sum');";
          echo "COMMIT;"; } | sqlite3 -bail "$DB" >/dev/null \
            || die "fallo $name (no se aplico nada de ese archivo)"
        aplicados=$((aplicados + 1))
    elif [ "$prev" != "$sum" ]; then
        log "AVISO: $name cambio despues de aplicarse; no se re-ejecuta. Cree un archivo nuevo (p.ej. 03_...sql)."
    fi
done

[ "$(sqlite3 "$DB" 'PRAGMA integrity_check;')" = "ok" ] || die "integrity_check fallo"
log "$aplicados script(s) nuevo(s). Tablas: $(sqlite3 "$DB" "SELECT group_concat(name, ', ') FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")"
