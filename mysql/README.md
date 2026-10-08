# MySQL 8.4 LTS (dev) — DataHub

```powershell
cd mysql
copy .env.example .env
docker compose up -d --build
docker compose ps        # esperar "healthy"
```

| Cliente | Valor |
|---|---|
| Host / puerto | `localhost:3307` (3306 queda para SingleStore) |
| Usuario app | `datahub` / `APP_PASSWORD` — base `GNBPE_DATAHUB` |
| Admin | `root` / `MYSQL_ROOT_PASSWORD` |
| Desde otro contenedor en `mysql-net` | `mysql-dev:3306` |

```
mysql+pymysql://datahub:DataHub_2026.App@localhost:3307/GNBPE_DATAHUB?charset=utf8mb4
jdbc:mysql://localhost:3307/GNBPE_DATAHUB?allowPublicKeyRetrieval=true&useSSL=false
```
Consola: `docker exec -it mysql-dev mysql -u datahub -p GNBPE_DATAHUB`

## Notas
- **Autenticacion**: 8.4 usa `caching_sha2_password` (`mysql_native_password` viene desactivado). Con PyMySQL instale `cryptography` (`pip install pymysql cryptography`); en DBeaver/JDBC active `allowPublicKeyRetrieval=true`.
- **init/**: `*.sql`, `*.sql.gz` y `*.sh` corren solo en el primer arranque (volumen vacio), sobre la base `APP_DB`. Tras editarlos: `docker compose down -v && docker compose up -d --build`.
- **conf/datahub.cnf**: utf8mb4, zona horaria `-05:00`, slow log. Se copia a la imagen (montado desde Windows MySQL lo ignoraria). Requiere `--build` tras cambiarlo.
- **Passwords**: cambiar `.env` despues del primer arranque no las cambia; use `ALTER USER`.
- **Reset total**: `docker compose down -v`.
