# SQLite (dev)

SQLite no es un servidor: es un archivo. Este stack solo **crea y migra** `data/datahub.db`
y levanta un visor web. Desde Python/DBeaver se abre el archivo directamente.

```powershell
cd sqlite
copy .env.example .env
docker compose up -d --build     # crea data\datahub.db y aplica init\*.sql
docker compose logs sqlite       # ver que scripts se aplicaron
```
Visor web: http://localhost:8082

| Uso | Valor |
|---|---|
| Archivo (Windows) | `sqlite\data\datahub.db` |
| Python | `sqlite3.connect(r"...\sqlite\data\datahub.db")` |
| SQLAlchemy | `sqlite:///C:/.../sqlite/data/datahub.db` |
| DBeaver | nueva conexion SQLite -> seleccionar el archivo |
| Consola | `docker compose run --rm sqlite sqlite3 /data/datahub.db` |

## Migraciones (init/)
- Cada `init/*.sql` se aplica **una sola vez**, en orden, dentro de una transaccion, y queda en la tabla `_migraciones`. No ponga `BEGIN`/`COMMIT` dentro.
- Para cambiar el esquema cree un archivo nuevo (`02_...sql`); si edita uno ya aplicado, se avisa y no se re-ejecuta.
- Aplicar nuevos: `docker compose up --build sqlite` (o `docker compose run --rm sqlite` tras reconstruir).
- `01_esquema_ejemplo.sql` es un ejemplo (`etl_control`); reemplacelo por su esquema.

## Notas
- **No escriba a la vez** desde Windows y desde el contenedor: el bloqueo de archivos de SQLite no es fiable sobre carpetas montadas. Leer en paralelo esta bien.
- `PRAGMA foreign_keys = ON` es por conexion: actívelo en cada cliente si usa FKs.
- Modo `journal_mode=DELETE` (no WAL) por compatibilidad con carpetas de Windows/OneDrive.
- **OneDrive**: la carpeta esta en OneDrive; si sincroniza el `.db` mientras se escribe puede generar copias en conflicto. Para cargas pesadas mueva `data/` fuera de OneDrive.
- **Reset**: borrar `data\datahub.db` y `docker compose up --build sqlite`.
