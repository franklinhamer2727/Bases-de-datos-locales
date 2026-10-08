# MariaDB 11.4 LTS (dev) — DataHub

```powershell
cd mariadb
copy .env.example .env
docker compose up -d --build
docker compose ps        # esperar "healthy"
```

| Cliente | Valor |
|---|---|
| Host / puerto | `localhost:3308` |
| Usuario app | `datahub` / `APP_PASSWORD` — base `GNBPE_DATAHUB` |
| Admin | `root` / `MARIADB_ROOT_PASSWORD` |
| Desde otro contenedor en `mariadb-net` | `mariadb-dev:3306` |

```
mariadb+mariadbconnector://datahub:DataHub_2026.App@localhost:3308/GNBPE_DATAHUB
mysql+pymysql://datahub:DataHub_2026.App@localhost:3308/GNBPE_DATAHUB?charset=utf8mb4
jdbc:mariadb://localhost:3308/GNBPE_DATAHUB
```
Consola: `docker exec -it mariadb-dev mariadb -u datahub -p GNBPE_DATAHUB`

## Notas
- **init/**: `*.sql`, `*.sql.gz`, `*.sh` corren solo en el primer arranque (volumen vacio). Tras editarlos: `docker compose down -v && docker compose up -d --build`.
- **conf/datahub.cnf**: utf8mb4 (`uca1400`), zona `-05:00`, slow log. Copiado a la imagen; `--build` tras cambiarlo.
- **Passwords**: cambiar `.env` despues del primer arranque no las cambia; use `ALTER USER`.
- **MySQL vs MariaDB**: protocolo compatible, pero no comparten volumen ni formato de datos; no apunte uno al volumen del otro.
- **Reset total**: `docker compose down -v`.
