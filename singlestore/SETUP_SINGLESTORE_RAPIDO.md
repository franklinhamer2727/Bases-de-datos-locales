# 🚀 SINGLESTORE CON DOCKER-COMPOSE - SETUP RÁPIDO

## 1️⃣ LEVANTAR SINGLESTORE

```bash
# Navega al directorio del proyecto
cd /ruta/a/tu/proyecto

# Inicia el contenedor
docker-compose -f docker-compose-singlestore.yml up -d

# Verifica que está corriendo
docker-compose -f docker-compose-singlestore.yml ps
```

**Esperado:**
```
CONTAINER ID   IMAGE                    STATUS              PORTS
abc123...      singlestore/cluster      Up (healthy)        0.0.0.0:3306->3306/tcp
```

## 2️⃣ ESPERAR A QUE ESTÉ LISTO

```bash
# Esperar a que el healthcheck sea exitoso (30-40 segundos)
docker-compose -f docker-compose-singlestore.yml exec singlestore \
  mysql -h localhost -u root -p'singlestore_root_2024' -e "SELECT 1"
```

## 3️⃣ CREAR BASE DE DATOS Y USUARIO

```bash
# Opción A: Directo desde línea de comandos
docker-compose -f docker-compose-singlestore.yml exec singlestore \
  mysql -h localhost -u root -p'singlestore_root_2024' < init-singlestore.sql

# Opción B: Interactivo (si prefieres ver los comandos)
docker-compose -f docker-compose-singlestore.yml exec -it singlestore \
  mysql -h localhost -u root -p'singlestore_root_2024'
```

Si usas Opción B, copia/pega el contenido de `init-singlestore.sql` en la consola MySQL.

## 4️⃣ CREDENCIALES PARA CONECTARTE

```
Host:     localhost (o IP de tu máquina)
Puerto:   3306
Usuario:  app_user
Password: app_password_2024
Database: app_db
```

### Usuarios disponibles:
- **root** (admin): `singlestore_root_2024`
- **app_user** (app): `app_password_2024`
- **dev_user** (dev): `dev_password_2024`

### URLs:
- **Web UI (Management Studio)**: http://localhost:8080
- **MySQL Protocol**: localhost:3306

## 5️⃣ CONECTARSE DESDE PYTHON

### Opción A: Conexión Simple
```python
import mysql.connector

conn = mysql.connector.connect(
    host='localhost',
    port=3306,
    user='app_user',
    password='app_password_2024',
    database='app_db'
)

cursor = conn.cursor()
cursor.execute("SELECT * FROM usuarios")
for row in cursor.fetchall():
    print(row)
cursor.close()
conn.close()
```

### Opción B: Con Pandas (RECOMENDADO)
```python
import pandas as pd
from sqlalchemy import create_engine

engine = create_engine(
    "mysql+pymysql://app_user:app_password_2024@localhost:3306/app_db"
)

# Leer
df = pd.read_sql_table('usuarios', engine)
print(df)

# Escribir
df.to_sql('usuarios', engine, if_exists='append', index=False)
```

### Opción C: Con PySpark
```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("SingleStore").getOrCreate()

jdbc_url = "jdbc:mysql://localhost:3306/app_db"
jdbc_properties = {
    "user": "app_user",
    "password": "app_password_2024",
    "driver": "com.mysql.jdbc.Driver"
}

df = spark.read.jdbc(jdbc_url, "usuarios", properties=jdbc_properties)
df.show()
```

## 6️⃣ COMANDOS ÚTILES

### Ver logs
```bash
docker-compose -f docker-compose-singlestore.yml logs -f singlestore
```

### Entrar a la consola MySQL
```bash
docker-compose -f docker-compose-singlestore.yml exec -it singlestore \
  mysql -h localhost -u root -p'singlestore_root_2024'
```

### Detener el contenedor
```bash
docker-compose -f docker-compose-singlestore.yml down
```

### Reiniciar (mantiene datos)
```bash
docker-compose -f docker-compose-singlestore.yml restart singlestore
```

### Borrar todo (incluyendo datos)
```bash
docker-compose -f docker-compose-singlestore.yml down -v
```

## 7️⃣ VERIFICAR LA CONEXIÓN

Ejecuta este script:
```bash
python3 connect_singlestore.py
```

**Salida esperada:**
```
✅ Conexión exitosa!
✅ Versión SingleStore: 8.x.x
📦 Bases de datos disponibles:
   - information_schema
   - memsql
   - app_db
📋 Tablas en 'app_db':
   - usuarios
📊 Usuarios en la base de datos (3 total):
...
```

## 8️⃣ EJECUTAR SCRIPTS DE PRUEBA

### Test básico
```bash
python3 connect_singlestore.py
```

### Test con inserción
```bash
python3 connect_singlestore.py --insert
```

### Test con Pandas y PySpark
```bash
python3 singlestore_pandas_pyspark.py
```

## 9️⃣ SUBIR DATOS

### Desde CSV
```python
import pandas as pd
from sqlalchemy import create_engine

# Leer CSV
df = pd.read_csv('mi_archivo.csv')

# Conectar
engine = create_engine(
    "mysql+pymysql://app_user:app_password_2024@localhost:3306/app_db"
)

# Subir
df.to_sql('mi_tabla', engine, if_exists='append', index=False)
print(f"✅ {len(df)} registros subidos")
```

### Desde Parquet
```python
import pandas as pd
from sqlalchemy import create_engine

# Leer Parquet
df = pd.read_parquet('mi_archivo.parquet')

# Conectar y subir
engine = create_engine(
    "mysql+pymysql://app_user:app_password_2024@localhost:3306/app_db"
)
df.to_sql('mi_tabla', engine, if_exists='append', index=False)
```

### Desde JSON
```python
import pandas as pd
from sqlalchemy import create_engine

# Leer JSON
df = pd.read_json('mi_archivo.json')

# Conectar y subir
engine = create_engine(
    "mysql+pymysql://app_user:app_password_2024@localhost:3306/app_db"
)
df.to_sql('mi_tabla', engine, if_exists='append', index=False)
```

## ✅ CHECKLIST FINAL

- [ ] Docker-compose corriendo (`docker ps`)
- [ ] SingleStore healthy
- [ ] Base de datos `app_db` creada
- [ ] Usuario `app_user` creado
- [ ] Tabla `usuarios` con datos
- [ ] Conexión desde Python exitosa
- [ ] Puedo leer datos con pandas
- [ ] Puedo escribir datos desde Python

## 🆘 TROUBLESHOOTING

### Error: "Connection refused"
```bash
# Verifica que el contenedor esté corriendo
docker-compose -f docker-compose-singlestore.yml ps

# Verifica logs
docker-compose -f docker-compose-singlestore.yml logs singlestore

# Espera más tiempo (SingleStore puede tardar)
sleep 60
```

### Error: "Access denied for user"
```bash
# Verifica credenciales en .env-singlestore
# Por defecto:
# user: app_user
# password: app_password_2024
```

### Error: "Unknown database 'app_db'"
```bash
# Verifica que se ejecutó init-singlestore.sql
docker-compose -f docker-compose-singlestore.yml exec singlestore \
  mysql -h localhost -u root -p'singlestore_root_2024' -e "SHOW DATABASES"
```

### Error: "pymysql/mysql not installed"
```bash
# Instala dependencias
pip install mysql-connector-python PyMySQL pandas sqlalchemy
```

## 📚 DOCUMENTACIÓN ADICIONAL

- **Docs Oficiales**: https://docs.singlestore.com/
- **SingleStore + Docker**: https://docs.singlestore.com/cloud/reference/docker-quick-start-guide/
- **SingleStore + Python**: https://docs.singlestore.com/managed-service/en/developer-guide/using-python/

---

## 🎯 RESUMEN RÁPIDO

```bash
# 1. Levantar
docker-compose -f docker-compose-singlestore.yml up -d

# 2. Crear BD
docker-compose -f docker-compose-singlestore.yml exec singlestore \
  mysql -h localhost -u root -p'singlestore_root_2024' < init-singlestore.sql

# 3. Verificar
python3 connect_singlestore.py

# 4. Usar desde Python
python3 -c "
import pandas as pd
from sqlalchemy import create_engine

engine = create_engine('mysql+pymysql://app_user:app_password_2024@localhost:3306/app_db')
df = pd.read_sql_table('usuarios', engine)
print(df)
"
```

✅ **¡Listo!** Tienes SingleStore corriendo con datos accesibles desde Python.
