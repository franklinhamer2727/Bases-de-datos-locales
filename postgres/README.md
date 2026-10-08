# PostgreSQL 17 (dev) — DataHub

## Levantar
```powershell
cd postgres
copy .env.example .env        # ajustar passwords si se desea
docker compose up -d --build
docker compose ps             # esperar STATUS = healthy
```
`healthy` = el rol `datahub` ya se conecta por TCP a su base (la inicializacion termino).

pgAdmin (opcional): `docker compose --profile tools up -d` -> http://localhost:5050
(entra con `PGADMIN_EMAIL` / `PGADMIN_PASSWORD`; el servidor ya viene registrado, pide la password de `datahub`).

## Conectar
| Cliente | Valor |
|---|---|
| Host / puerto (DBeaver, psql, Python) | `localhost:5432` |
| Usuario app | `datahub` / `APP_PASSWORD` del `.env` (base `GNBPE_DATAHUB`) |
| Admin | `postgres` / `POSTGRES_PASSWORD` |
| Desde otro contenedor en `postgres-net` | host `postgres-dev`, puerto `5432` |

```
postgresql://datahub:DataHub_2026.App@localhost:5432/GNBPE_DATAHUB          # psycopg / SQLAlchemy (+psycopg)
jdbc:postgresql://localhost:5432/GNBPE_DATAHUB                              # Spark / DBeaver
```
Consola: `docker exec -it postgres-dev psql -U datahub -d GNBPE_DATAHUB`

## Trabajar junto a SQL Server
Cada stack tiene su propia red. Desde tu PC (Python, DBeaver) usa `localhost:1433` y `localhost:5432`.
Desde un contenedor hacia el otro motor usa `host.docker.internal` (Docker Desktop).

## Notas
- **Scripts de inicio**: `init/*.sh` y `init/*.sql` corren **solo en el primer arranque** (volumen vacio); es el comportamiento de la imagen oficial. Para re-ejecutarlos: `docker compose down -v` (borra datos) y volver a levantar. Tras editar `init/` hay que reconstruir: `--build`.
- **Passwords**: cambiar `.env` despues del primer arranque NO cambia las passwords. Use `ALTER ROLE datahub PASSWORD '...';` como `postgres`.
- **Aislamiento**: el rol `datahub` no es superusuario y es dueno solo de su base y del schema `public`; las demas bases le estan cerradas.
- **Memoria**: los parametros `PG_*` del `.env` estan pensados para ~4 GB. Si Docker/WSL tiene menos, baje `PG_SHARED_BUFFERS` y `PG_EFFECTIVE_CACHE_SIZE`.
- **Puerto ocupado** (Postgres local instalado en Windows): `PG_PORT=5433` en `.env`.
- **Version**: fijada en 17. `postgres:18` guarda los datos en otra ruta (`/var/lib/postgresql`); no basta con cambiar la etiqueta.
- **Reset total** (borra los datos): `docker compose down -v`.
