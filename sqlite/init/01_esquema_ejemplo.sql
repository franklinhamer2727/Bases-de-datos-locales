-- Ejemplo: tabla de control de cargas. Reemplace o agregue 02_..., 03_...
-- Cada archivo se aplica UNA vez (queda registrado en _migraciones), dentro de
-- una transaccion: no ponga BEGIN/COMMIT aqui.
CREATE TABLE IF NOT EXISTS etl_control (
    id        INTEGER PRIMARY KEY,
    proceso   TEXT    NOT NULL,
    estado    TEXT    NOT NULL CHECK (estado IN ('PENDIENTE', 'OK', 'ERROR')),
    filas     INTEGER,
    inicio    TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    fin       TEXT,
    detalle   TEXT
);

CREATE INDEX IF NOT EXISTS ix_etl_control_proceso ON etl_control (proceso, inicio);
