# MongoDB 8.0 (dev) — DataHub

```powershell
cd mongodb
copy .env.example .env
docker compose up -d --build
docker compose ps        # esperar "healthy"
```
mongo-express (opcional): `docker compose --profile tools up -d` -> http://localhost:8081 (`ME_USER` / `ME_PASSWORD`).

| Cliente | Valor |
|---|---|
| Usuario app | `datahub` / `APP_PASSWORD`, `authSource=GNBPE_DATAHUB` |
| Admin | `root` / `MONGO_ROOT_PASSWORD`, `authSource=admin` |
| Desde otro contenedor en `mongodb-net` | `mongodb-dev:27017` |

```
mongodb://datahub:DataHub_2026.App@localhost:27017/GNBPE_DATAHUB?authSource=GNBPE_DATAHUB    # pymongo / Compass
```
Consola: `docker exec -it mongodb-dev mongosh -u datahub -p --authenticationDatabase GNBPE_DATAHUB GNBPE_DATAHUB`

## Notas
- **El usuario app vive en su base** (`authSource=GNBPE_DATAHUB`, no `admin`). Es el error de conexion mas comun.
- **init/**: `*.js` y `*.sh` corren solo en el primer arranque. Tras editarlos: `docker compose down -v && docker compose up -d --build`.
- **Passwords**: cambiar `.env` despues del primer arranque no las cambia; use `db.changeUserPassword()`.
- **Transacciones / change streams** necesitan replica set; este stack es un nodo standalone (suficiente para CRUD, agregaciones e indices).
- **CPU**: MongoDB 5+ requiere AVX. Si el contenedor muere sin log en una VM vieja, use `MONGO_IMAGE=mongo:4.4`.
- **Reset total**: `docker compose down -v`.
