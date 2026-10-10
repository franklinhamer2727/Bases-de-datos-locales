# SQL Server 2022 (dev) — DataHub

## Levantar (recomendado)
```powershell
cd sqlserver
powershell -ExecutionPolicy Bypass -File .\levantar.ps1
```
El script: revisa que el puerto este libre (si no, usa 14333 y lo guarda en `.env`), levanta el
contenedor, espera a que quede `healthy` y **prueba el login de `sa` y de `datahub`**, tanto dentro
del contenedor como entrando por el puerto publicado (igual que DBeaver). Todo queda en `levantar.log`.

Manual: `docker compose up -d --build` y luego `docker exec sqlserver-dev verificar.sh`.

Si algo falla: `powershell -ExecutionPolicy Bypass -File .\diagnostico.ps1` (genera `diagnostico.txt`).

## Conectar
| Cliente | Valor |
|---|---|
| Servidor (SSMS / DBeaver / Azure Data Studio) | `host.docker.internal,1433` |
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
docker exec -it sqlserver-dev sqlcmd -C -S localhost -U datahub -P "Etl_Gnbpe_2026.Pw" -d GNBPE_DATAHUB
```

## Notas
- **Password de la app**: la politica de SQL Server rechaza passwords que contienen el nombre del
  usuario (`DataHub_...` para `datahub` falla con "not complex enough"). El arranque lo valida antes.
- **En cada arranque** el contenedor repara lo necesario: crea base/login si faltan, sincroniza la
  password de `datahub` con el `.env`, lo desbloquea, re-mapea el usuario si quedo huerfano, y si el
  volumen tenia otra password de `sa` intenta restablecerla a la del `.env`.
- **Scripts de inicio**: todo `init/*.sql` se ejecuta en orden alfabetico en cada arranque, asi que deben ser idempotentes (`IF NOT EXISTS ...`). Variables disponibles: `$(APP_DB)`, `$(APP_USER)`, `$(APP_PASSWORD)`. Tras agregar uno: `docker compose up -d --build`.
- **Password de sa**: `MSSQL_SA_PASSWORD` solo se aplica al crear el volumen. Para cambiarla despues use `ALTER LOGIN sa WITH PASSWORD = '...'` o borre el volumen. La de `APP_PASSWORD` si se re-sincroniza en cada arranque.
- **Collation**: `MSSQL_COLLATION` tambien aplica solo en el primer arranque.
- **Memoria**: SQL Server necesita al menos 2 GB. En Docker Desktop + WSL2 revise `%UserProfile%\.wslconfig` (`memory=6GB` o mas).
- **Reset total** (borra los datos): `docker compose down -v`.
- **Puerto ocupado** (ya hay un SQL Server local en 1433): cambie `MSSQL_PORT=14333` en `.env`.
