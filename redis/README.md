# Redis 8 (dev)

```powershell
cd redis
copy .env.example .env
docker compose up -d --build
docker compose ps        # esperar "healthy"
```
RedisInsight (opcional): `docker compose --profile tools up -d` -> http://localhost:5540
(si la conexion no aparece sola: host `redis-dev`, puerto `6379`, password `REDIS_PASSWORD`).

| Cliente | Valor |
|---|---|
| Host / puerto | `localhost:6379` |
| Password | `REDIS_PASSWORD` (usuario `default`) |
| Desde otro contenedor en `redis-net` | `redis-dev:6379` |

```
redis://:RedisDev_2026.Pass@localhost:6379/0        # redis-py: redis.from_url(...)
```
Consola: `docker exec -it redis-dev redis-cli` (ya autenticada via `REDISCLI_AUTH`).

## Notas
- **Persistencia**: AOF cada segundo + RDB en el volumen `redis_dev_data`; sobrevive a reinicios y `down` (no a `down -v`).
- **Memoria**: `REDIS_MAXMEMORY` (512 MB). Con `noeviction`, al llenarse rechaza escrituras. Para cache pura use `maxmemory-policy allkeys-lru` en `conf/redis.conf` y `--build`.
- **Redis 8** incluye JSON, Search, TimeSeries y Bloom sin modulos aparte.
- **Usuarios por aplicacion**: con ACL, p.ej. `ACL SETUSER etl on >Pass_2026 ~etl:* +@all -@dangerous`.
- **Aviso `vm.overcommit_memory`** en el log: es inofensivo en desarrollo.
- **Reset total**: `docker compose down -v`.
