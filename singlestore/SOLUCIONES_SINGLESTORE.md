# 🔧 SOLUCIONES PARA ERROR DE IMAGEN SINGLESTORE

## ❌ Problema
```
Error response from daemon: pull access denied for singlestore/cluster, 
repository does not exist or may require 'docker login'
```

## ✅ SOLUCIONES

### SOLUCIÓN 1: Usar MySQL en lugar de SingleStore (RECOMENDADO)

**Por qué funciona:**
- SingleStore es totalmente compatible con MySQL
- MySQL es público y no requiere credenciales
- El código Python es **exactamente igual**
- El rendimiento es comparable para desarrollo

**Pasos:**

```bash
# Usa el nuevo archivo docker-compose
docker-compose -f docker-compose-mysql-singlestore.yml up -d

# Espera 30 segundos
sleep 30

# Verifica que está corriendo
docker-compose -f docker-compose-mysql-singlestore.yml ps

# Conecta con Python (exactamente igual)
python3 connect_singlestore.py
```

**Cambios en código Python: NINGUNO**
- Los scripts funcionan tal cual porque MySQL es compatible

---

### SOLUCIÓN 2: Registrarse en SingleStore (Docker Hub)

Si quieres la imagen oficial de SingleStore:

```bash
# 1. Crear cuenta gratuita en https://hub.docker.com/r/singlestore/cluster
# 2. Hacer login
docker login

# 3. Ingresa tus credenciales

# 4. Intenta de nuevo
docker-compose -f docker-compose-singlestore.yml up -d
```

**Nota:** SingleStore tiene plan free pero requiere cuenta.

---

### SOLUCIÓN 3: Compilar desde Dockerfile

Compila tu propia imagen:

```bash
# Asegúrate de que Dockerfile-singlestore esté en el mismo directorio
docker build -t singlestore-custom:latest -f Dockerfile-singlestore .

# Edita docker-compose-singlestore.yml para usar tu imagen:
# Cambia:
#   image: singlestore/cluster:latest
# Por:
#   image: singlestore-custom:latest

docker-compose -f docker-compose-singlestore.yml up -d
```

---

## 🎯 RECOMENDACIÓN: OPCIÓN 1 (MySQL)

**Por estas razones:**

| Aspecto | MySQL | SingleStore |
|--------|-------|------------|
| **Disponibilidad** | ✅ Público | ❌ Requiere credenciales |
| **Instalación** | ✅ 1 minuto | ⚠️ Requiere registro |
| **Compatibilidad código** | ✅ 100% | ✅ 100% |
| **Performance dev** | ✅ Excelente | ✅ Excelente |
| **Licencia** | ✅ Libre | ⚠️ Free + Premium |

---

## 🚀 INICIO RÁPIDO CON MYSQL

### 1. Levantar
```bash
docker-compose -f docker-compose-mysql-singlestore.yml up -d
```

### 2. Verificar (después de 30 segundos)
```bash
docker-compose -f docker-compose-mysql-singlestore.yml ps
```

**Esperado:**
```
STATUS: Up (healthy)
```

### 3. Conectar con Python
```bash
python3 connect_singlestore.py
```

### 4. Código Python (NO CAMBIA)
```python
import mysql.connector

conn = mysql.connector.connect(
    host='localhost',
    port=3306,
    user='app_user',
    password='app_password_2024',
    database='app_db'
)

cursor = conn.cursor(dictionary=True)
cursor.execute("SELECT * FROM usuarios")
for row in cursor.fetchall():
    print(row)
cursor.close()
conn.close()
```

---

## 📝 CAMBIOS NECESARIOS

### Si usas docker-compose-mysql-singlestore.yml

**Ventajas vs docker-compose-singlestore.yml original:**
- ✅ Sin credenciales de Docker
- ✅ Inicialización automática de BD
- ✅ Tabla de usuarios ya creada
- ✅ Health check incluido
- ✅ Optimizaciones MySQL para máximo performance

**Credenciales (idénticas):**
```
Host: localhost
Puerto: 3306
Usuario: app_user
Password: app_password_2024
Database: app_db
```

---

## ✅ CHECKLIST

- [ ] Docker Desktop corriendo
- [ ] Ejecutar: `docker-compose -f docker-compose-mysql-singlestore.yml up -d`
- [ ] Esperar 30 segundos
- [ ] Verificar: `docker-compose -f docker-compose-mysql-singlestore.yml ps`
- [ ] Ver STATUS como "Up (healthy)"
- [ ] Ejecutar: `python3 connect_singlestore.py`
- [ ] Ver ✅ "Conexión exitosa!"

---

## 🆘 SI AÚN HAY PROBLEMAS

### Error: "Connection refused"
```bash
# Espera más tiempo
sleep 60

# Verifica logs
docker-compose -f docker-compose-mysql-singlestore.yml logs -f

# Reinicia
docker-compose -f docker-compose-mysql-singlestore.yml restart
```

### Error: "Access denied for user"
```bash
# Verifica que uses las credenciales correctas:
# user: app_user
# password: app_password_2024
# database: app_db
```

### Error: "Docker daemon not running"
```bash
# Abre Docker Desktop
# Espera 30 segundos
# Intenta de nuevo
```

---

## 📊 COMPARATIVA: MySQL vs SingleStore vs PostgreSQL

| Característica | MySQL | SingleStore | PostgreSQL |
|---|---|---|---|
| Protocolo | ✅ MySQL | ✅ MySQL | ❌ PostgreSQL |
| Disponibilidad | ✅ Público | ❌ Credenciales | ✅ Público |
| Tipo dato Vectorial | ❌ No | ✅ Sí (JSON) | ✅ pgvector |
| Distributed | ❌ No | ✅ Sí | ✅ Citrus |
| Analytics | ⭐⭐ Bueno | ⭐⭐⭐ Excelente | ⭐⭐⭐ Excelente |
| Setup fácil | ✅ Muy fácil | ✅ Fácil | ✅ Fácil |

**Para este proyecto: MySQL es la opción más práctica.**

---

## 🎓 PRÓXIMOS PASOS

1. **Usa docker-compose-mysql-singlestore.yml**
2. **Ejecuta los scripts Python sin cambios**
3. **Todo funciona igual que SingleStore**
4. **Si necesitas SingleStore real después, solo cambias la imagen**

---

## 💡 DATO: Migración futura

Si después necesitas SingleStore real en producción:

```yaml
# Solo cambia esta línea en el docker-compose
# De:
image: mysql:8.0-latest

# A:
image: singlestore/cluster:latest
```

**Los scripts Python siguen funcionando sin cambios** porque ambas usan protocolo MySQL.

---

✅ **Solución rápida: Usa MySQL, todo funciona igual**
