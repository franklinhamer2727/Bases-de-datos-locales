# SQL Server 2022 (dev) — DataHub

## Levantar
```powershell
cd sqlserver
copy .env.example .env      # ajustar passwords si se desea
docker compose up -d --build
docker compose ps           # esperar STATUS = healthy (1-2 min el primer arranque)
docker compose logs -f sqlserver   # lineas [init] muestran el progreso
```
`healthy` = motor arriba + `init/*.sql` aplicados + el login de la app conecta.

## Conectar
| Cliente | Valor |
|---|---|
| Servidor (SSMS / DBeaver / Azure Data Studio) | `localhost,1433` |
| Usuario app | `datahub` / `APP_PASSWORD` del `.env` (base `GNBPE_DATAHUB`) |
| Admin | `sa` / `MSSQL_SA_PASSWORD` |
| Cifrado | marcar **Trust server certificate** (certificado autofirmado) |
| Desde otro contenedor en `sqlserver-net` | host `sqlserver-dev`, puerto `1433` |

pyodbc:
```
DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost,1433;DATABASE=GNBPE_DATAHUB;UID=datahub;PWD=...;TrustServerCertificate=yes
```
Consola dentro del contenedor:
```powershell
docker exec -it sqlserver-dev sqlcmd -C -S localhost -U datahub -P "DataHub_2026.App" -d GNBPE_DATAHUB
```

## Notas
- **Scripts de inicio**: todo `init/*.sql` se ejecuta en orden alfabetico en cada arranque, asi que deben ser idempotentes (`IF NOT EXISTS ...`). Variables disponibles: `$(APP_DB)`, `$(APP_USER)`, `$(APP_PASSWORD)`. Tras agregar uno: `docker compose up -d --build`.
- **Password de sa**: `MSSQL_SA_PASSWORD` solo se aplica al crear el volumen. Para cambiarla despues use `ALTER LOGIN sa WITH PASSWORD = '...'` o borre el volumen. La de `APP_PASSWORD` si se re-sincroniza en cada arranque.
- **Collation**: `MSSQL_COLLATION` tambien aplica solo en el primer arranque.
- **Memoria**: SQL Server necesita al menos 2 GB. En Docker Desktop + WSL2 revise `%UserProfile%\.wslconfig` (`memory=6GB` o mas).
- **Reset total** (borra los datos): `docker compose down -v`.
- **Puerto ocupado** (ya hay un SQL Server local en 1433): cambie `MSSQL_PORT=14333` en `.env`.
