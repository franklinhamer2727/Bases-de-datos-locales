# DBeaver web (CloudBeaver Community)

DBeaver en el navegador, sin instalar nada en Windows. Viene con las conexiones
a todas las bases relacionales de esta carpeta ya registradas.

```powershell
cd dbeaver
copy .env.example .env
docker compose up -d --build
docker compose ps          # esperar "healthy" (~1 min la primera vez)
```
Abrir **http://localhost:8978** e ingresar con `cbadmin` / `CB_ADMIN_PASSWORD` del `.env`.

## Conexiones precargadas
| Conexion | Destino | Usuario |
|---|---|---|
| SQL Server 2022 (dev) | `host.docker.internal:1433` / GNBPE_DATAHUB | datahub |
| PostgreSQL 17 (dev) | `host.docker.internal:5432` / GNBPE_DATAHUB | datahub |
| MySQL 8.4 (dev) | `host.docker.internal:3307` / GNBPE_DATAHUB | datahub |
| MariaDB 11.4 (dev) | `host.docker.internal:3308` / GNBPE_DATAHUB | datahub |
| SQLite (datahub.db) | archivo `../sqlite/data/datahub.db` | — |
| SingleStore (dev) | `host.docker.internal:3306` | root |

Solo responden las bases que esten levantadas. Las passwords son las de los `.env.example`
de cada carpeta; CloudBeaver las cifra en su workspace en la primera conexion.

**SQLite (una sola vez):** CloudBeaver trae desactivados los drivers de archivo local.
Menu de usuario -> *Administration* -> *Server Configuration* -> *Disabled drivers*:
quitar **SQLite** -> *Save*. Queda guardado en el volumen.

**MongoDB y Redis** no los soporta la edicion Community (son de DBeaver PRO).
Use mongo-express (`mongodb`, :8081) y RedisInsight (`redis`, :5540) con `--profile tools`.

## Por que es ligero
- Imagen oficial sin agregados (los drivers JDBC ya vienen dentro; no descarga nada al conectar).
- Java limitado a 768 MB de heap con GC serial; contenedor topado en 1 GB (`.env`).
- Publicado solo en `127.0.0.1`: no queda expuesto a la red local.
- Si no lo usa: `docker compose stop` (no pierde conexiones ni scripts).

## Notas
- **Las conexiones se cargan solo en el primer arranque** (workspace vacio). Si cambio passwords
  en los `.env` de las bases, edite la conexion en la UI, o ajuste `conf/conexiones.json` y
  reinicie el workspace: `docker compose down -v && docker compose up -d --build`
  (borra tambien scripts SQL guardados y usuarios creados en CloudBeaver).
- **Agregar otra conexion**: boton *+* -> *New connection*. Para una base en Docker use host
  `host.docker.internal` y el puerto publicado en Windows (no `localhost`: dentro del contenedor
  `localhost` es el propio CloudBeaver).
- **Usuarios**: el admin puede crear usuarios en *Administration -> Users* y darles acceso a
  conexiones concretas (acceso anonimo desactivado).
- **SQLite**: no escriba al mismo tiempo desde CloudBeaver, sqlite-web y Windows.
- **Version**: usa `latest`. Para fijarla: `CB_IMAGE=dbeaver/cloudbeaver:<version>` en `.env` y `--build`.
- **Puerto ocupado**: `CB_PORT=8979` en `.env`.
