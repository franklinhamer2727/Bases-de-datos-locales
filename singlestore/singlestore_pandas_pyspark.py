#!/usr/bin/env python3
# ============================================================================
# SINGLESTORE CON PANDAS Y PYSPARK
# ============================================================================
# Ejemplos de cómo conectarse a SingleStore desde Pandas y PySpark

import mysql.connector
import pandas as pd
from sqlalchemy import create_engine
import json

# ============================================================================
# CONFIGURACIÓN GENERAL
# ============================================================================

# Credenciales
SINGLESTORE_HOST = 'localhost'
SINGLESTORE_PORT = 3306
SINGLESTORE_USER = 'app_user'
SINGLESTORE_PASSWORD = 'app_password_2024'
SINGLESTORE_DATABASE = 'app_db'

# ============================================================================
# OPCIÓN 1: PANDAS + SQLAlchemy (RECOMENDADO)
# ============================================================================

def read_singlestore_pandas():
    """Lee datos de SingleStore con Pandas"""

    print("\n" + "="*70)
    print("OPCIÓN 1: PANDAS + SQLAlchemy (RECOMENDADO)")
    print("="*70)

    # String de conexión
    connection_string = (
        f"mysql+pymysql://{SINGLESTORE_USER}:{SINGLESTORE_PASSWORD}@"
        f"{SINGLESTORE_HOST}:{SINGLESTORE_PORT}/{SINGLESTORE_DATABASE}"
    )

    try:
        # Crear engine
        engine = create_engine(connection_string)

        # Leer tabla completa
        print("\n[*] Leyendo tabla 'usuarios'...")
        df = pd.read_sql_table('usuarios', engine)

        print(f"✅ {len(df)} registros leídos")
        print(f"\nDatos:")
        print(df)

        # Leer con query personalizada
        print("\n[*] Leyendo con query personalizada...")
        sql_query = "SELECT nombre, email, edad FROM usuarios WHERE edad > 25"
        df_filtered = pd.read_sql(sql_query, engine)

        print(f"✅ {len(df_filtered)} registros con edad > 25")
        print(df_filtered)

        return df, engine

    except Exception as e:
        print(f"❌ Error: {e}")
        return None, None

def write_singlestore_pandas(df, engine):
    """Escribe datos a SingleStore con Pandas"""

    print("\n[*] Escribiendo datos a SingleStore...")

    try:
        # Opción 1: Append (agregar a tabla existente)
        df.to_sql('usuarios', engine, if_exists='append', index=False)
        print("✅ Datos insertados (append)")

        # Opción 2: Replace (reemplazar tabla)
        # df.to_sql('usuarios', engine, if_exists='replace', index=False)
        # print("✅ Tabla reemplazada")

        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

# ============================================================================
# OPCIÓN 2: MYSQL.CONNECTOR DIRECTO
# ============================================================================

def read_singlestore_mysql_connector():
    """Lee datos con mysql.connector"""

    print("\n" + "="*70)
    print("OPCIÓN 2: MYSQL.CONNECTOR DIRECTO")
    print("="*70)

    try:
        # Conectar
        conn = mysql.connector.connect(
            host=SINGLESTORE_HOST,
            port=SINGLESTORE_PORT,
            user=SINGLESTORE_USER,
            password=SINGLESTORE_PASSWORD,
            database=SINGLESTORE_DATABASE
        )

        # Leer con pandas
        print("\n[*] Leyendo tabla 'usuarios'...")
        df = pd.read_sql('SELECT * FROM usuarios', conn)

        print(f"✅ {len(df)} registros leídos")
        print(df)

        conn.close()
        return df

    except Exception as e:
        print(f"❌ Error: {e}")
        return None

# ============================================================================
# OPCIÓN 3: PYSPARK
# ============================================================================

def read_singlestore_pyspark():
    """Lee datos con PySpark"""

    print("\n" + "="*70)
    print("OPCIÓN 3: PYSPARK")
    print("="*70)

    try:
        from pyspark.sql import SparkSession

        # Crear sesión Spark
        spark = SparkSession.builder \
            .appName("SingleStore") \
            .getOrCreate()

        # Configuración JDBC
        jdbc_url = (
            f"jdbc:mysql://{SINGLESTORE_HOST}:{SINGLESTORE_PORT}/"
            f"{SINGLESTORE_DATABASE}"
        )

        jdbc_properties = {
            "user": SINGLESTORE_USER,
            "password": SINGLESTORE_PASSWORD,
            "driver": "com.mysql.jdbc.Driver"
        }

        # Leer tabla con Spark
        print("\n[*] Leyendo tabla 'usuarios' con Spark...")
        df_spark = spark.read.jdbc(
            url=jdbc_url,
            table="usuarios",
            properties=jdbc_properties
        )

        print(f"✅ DataFrame cargado")
        print(f"   Rows: {df_spark.count()}")
        print(f"   Columns: {', '.join(df_spark.columns)}")

        # Mostrar datos
        df_spark.show()

        # Convertir a Pandas si lo necesitas
        df_pandas = df_spark.toPandas()

        return df_spark, spark

    except Exception as e:
        print(f"❌ Error (¿Está instalado PySpark?): {e}")
        return None, None

# ============================================================================
# OPCIÓN 4: BULK INSERT CON PANDAS
# ============================================================================

def bulk_insert_pandas():
    """Inserta muchos registros eficientemente"""

    print("\n" + "="*70)
    print("OPCIÓN 4: BULK INSERT (EFICIENTE)")
    print("="*70)

    # Crear muchos registros
    datos = {
        'nombre': [f'Usuario {i}' for i in range(1000)],
        'email': [f'user{i}@example.com' for i in range(1000)],
        'edad': [20 + (i % 50) for i in range(1000)]
    }

    df = pd.DataFrame(datos)

    print(f"\n[*] Insertando {len(df)} registros...")

    try:
        connection_string = (
            f"mysql+pymysql://{SINGLESTORE_USER}:{SINGLESTORE_PASSWORD}@"
            f"{SINGLESTORE_HOST}:{SINGLESTORE_PORT}/{SINGLESTORE_DATABASE}"
        )

        engine = create_engine(connection_string)
        df.to_sql('usuarios', engine, if_exists='append', index=False, chunksize=100)

        print(f"✅ {len(df)} registros insertados exitosamente")
        return True

    except Exception as e:
        print(f"❌ Error: {e}")
        return False

# ============================================================================
# EXPORTAR A CSV, JSON, PARQUET
# ============================================================================

def export_data(df):
    """Exporta datos a diferentes formatos"""

    print("\n[*] Exportando datos...")

    # CSV
    df.to_csv('usuarios.csv', index=False)
    print("✅ Exportado a usuarios.csv")

    # JSON
    df.to_json('usuarios.json', orient='records', indent=2)
    print("✅ Exportado a usuarios.json")

    # Parquet (más comprimido y rápido)
    df.to_parquet('usuarios.parquet')
    print("✅ Exportado a usuarios.parquet")

# ============================================================================
# MAIN
# ============================================================================

if __name__ == '__main__':

    print("\n" + "="*70)
    print("EJEMPLOS DE CONEXIÓN A SINGLESTORE")
    print("="*70)

    # Opción 1: Pandas (RECOMENDADO)
    df, engine = read_singlestore_pandas()

    if df is not None:
        # Exportar
        export_data(df)

        # Crear datos de ejemplo para insertar
        new_data = pd.DataFrame({
            'nombre': ['Test User'],
            'email': ['test@example.com'],
            'edad': [25]
        })

        print("\n[*] Insertando nuevo registro...")
        write_singlestore_pandas(new_data, engine)

    # Opción 2: MySQL Connector directo
    df2 = read_singlestore_mysql_connector()

    # Opción 3: PySpark (si está instalado)
    # df_spark, spark = read_singlestore_pyspark()

    print("\n" + "="*70)
    print("✅ Ejemplos completados")
    print("="*70)
