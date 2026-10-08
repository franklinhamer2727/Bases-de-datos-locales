# Bases de datos locales (Docker)

Una carpeta por motor, todas con la misma estructura:
`docker-compose.yml` + `.env.example` + `Dockerfile` + `init/` + `README.md`.

```powershell
cd <carpeta>
copy .env.example .env
docker compose up -d --build
docker compose ps            # esperar "healthy"
```

| Motor | Carpeta | Puerto host | UI opcional (`--profile tools`) | Contenedor / red |
|---|---|---|---|---|
| SQL Server 2022 | `sqlserver` | 1433 | — (SSMS / Azure Data Studio) | `sqlserver-dev` / `sqlserver-net` |
| PostgreSQL 17 | `postgres` | 5432 | pgAdmin http://localhost:5050 | `postgres-dev` / `postgres-net` |
| MySQL 8.4 LTS | `mysql` | **3307** | — | `mysql-dev` / `mysql-net` |
| MariaDB 11.4 LTS | `mariadb` | **3308** | — | `mariadb-dev` / `mariadb-net` |
| SQLite 3 | `sqlite` | — (archivo `data/datahub.db`) | sqlite-web http://localhost:8082 (siempre) | `sqlite-web-dev` |
| MongoDB 8.0 | `mongodb` | 27017 | mongo-express http://localhost:8081 | `mongodb-dev` / `mongodb-net` |
| Redis 8 | `redis` | 6379 | RedisInsight http://localhost:5540 | `redis-dev` / `redis-net` |
| SingleStore | `singlestore` | 3306, 8080, 9000 | Studio http://localhost:8080 | `singlestore-dev` |
| **DBeaver web** (CloudBeaver) | `dbeaver` | 8978 | cliente para todas las anteriores (salvo MongoDB/Redis) | `cloudbeaver-dev` |

Ningun puerto se repite: se pueden levantar todos a la vez. MySQL y MariaDB no usan 3306 porque lo ocupa SingleStore.

Cliente unico: `dbeaver/` levanta DBeaver en el navegador con las conexiones ya registradas.

## Convenciones comunes
- **Usuario de aplicacion** `datahub` / base `GNBPE_DATAHUB` en todos los motores relacionales y en MongoDB. El admin (`sa`, `postgres`, `root`) es solo para administrar; Airflow/ETL usa `datahub`.
- **`healthy` significa listo de verdad**: el healthcheck conecta con el usuario de la app por red, no solo comprueba que el proceso exista.
- **Datos en volumenes con nombre** (`<motor>_dev_data`), no en carpetas de Windows (fallan por permisos). Excepcion: SQLite, cuyo archivo se deja en `sqlite/data` a proposito.
- **Configuracion horneada en la imagen** (`Dockerfile` + `sed` para quitar CRLF): montados desde Windows, MySQL ignora los `.cnf` y los `.sh` fallan por `\r`. Tras cambiar `init/` o `conf/`: `--build`.
- **init/ corre solo en el primer arranque** (volumen vacio) en Postgres, MySQL, MariaDB y MongoDB. SQL Server lo re-ejecuta en cada arranque (scripts idempotentes). SQLite aplica cada script una vez y lo registra en `_migraciones`.
- **`.env` no se versiona** (`.gitignore`); `.env.example` si.

## Comandos utiles
```powershell
docker compose logs -f              # ver arranque / init
docker compose stop                 # apagar sin perder datos
docker compose down                 # quitar contenedores (datos se conservan)
docker compose down -v              # BORRAR datos y volver a inicializar
docker system df -v                 # espacio usado por volumenes
```

## Memoria
Limites por defecto: SQL Server ~2 GB (min. del motor), Postgres 4 GB, MySQL/MariaDB/MongoDB 2 GB, Redis 1 GB.
Todos juntos superan 12 GB: levante solo los que use, o suba la memoria de WSL2 en `%UserProfile%\.wslconfig`:
```ini
[wsl2]
memory=12GB
```
(luego `wsl --shutdown` y reabrir Docker Desktop).

## Conectar entre motores
Cada stack tiene su propia red. Desde Windows (Python, DBeaver, Spark local) use `localhost:<puerto>`.
Desde dentro de un contenedor hacia otro motor use `host.docker.internal:<puerto>`.

> La carpeta esta dentro de OneDrive. Los volumenes Docker no se ven afectados, pero el archivo de SQLite si se sincroniza: para cargas pesadas, saque `sqlite/data` de OneDrive.
