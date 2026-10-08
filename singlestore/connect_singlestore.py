#!/usr/bin/env python3
# ============================================================================
# CONEXIÓN A SINGLESTORE DESDE PYTHON
# ============================================================================
# Uso:
#   python connect_singlestore.py              # Test conexión básica
#   python connect_singlestore.py --insert     # Insertar datos
#   python connect_singlestore.py --query      # Ejecutar query
# ============================================================================

import mysql.connector
from mysql.connector import Error
import sys
from datetime import datetime

# ============================================================================
# CONFIGURACIÓN
# ============================================================================
config = {
    'host': 'localhost',           # O IP donde esté SingleStore
    'port': 3306,                  # Puerto por defecto MySQL
    'user': 'app_user',            # Usuario creado en init-singlestore.sql
    'password': 'app_password_2024',  # Password del usuario
    'database': 'app_db',          # Base de datos
    'autocommit': True,            # Auto-commit de cambios
    'get_warnings': True,
    'raise_on_warnings': False
}

class SingleStoreConnector:
    """Conector a SingleStore"""

    def __init__(self, config):
        self.config = config
        self.connection = None
        self.cursor = None

    def connect(self):
        """Conectarse a SingleStore"""
        try:
            print(f"[*] Conectando a SingleStore en {self.config['host']}:{self.config['port']}...")
            self.connection = mysql.connector.connect(**self.config)
            self.cursor = self.connection.cursor(dictionary=True)
            print("✅ Conexión exitosa!")
            return True
        except Error as e:
            print(f"❌ Error de conexión: {e}")
            return False

    def test_connection(self):
        """Prueba la conexión y muestra info del servidor"""
        if not self.connection:
            print("❌ No hay conexión activa")
            return False

        try:
            # Query de prueba
            self.cursor.execute("SELECT VERSION() as version")
            result = self.cursor.fetchone()
            print(f"\n✅ Versión SingleStore: {result['version']}")

            # Bases de datos
            self.cursor.execute("SHOW DATABASES")
            databases = self.cursor.fetchall()
            print(f"📦 Bases de datos disponibles:")
            for db in databases:
                print(f"   - {list(db.values())[0]}")

            # Tablas en app_db
            self.cursor.execute("SHOW TABLES FROM app_db")
            tables = self.cursor.fetchall()
            print(f"\n📋 Tablas en 'app_db':")
            for table in tables:
                print(f"   - {list(table.values())[0]}")

            return True
        except Error as e:
            print(f"❌ Error: {e}")
            return False

    def query(self, sql, params=None):
        """Ejecuta una query y retorna resultados"""
        try:
            if params:
                self.cursor.execute(sql, params)
            else:
                self.cursor.execute(sql)

            # Si es SELECT, retornar resultados
            if sql.strip().upper().startswith('SELECT'):
                return self.cursor.fetchall()

            # Si es INSERT/UPDATE/DELETE, retornar rows affected
            return {'rows_affected': self.cursor.rowcount}

        except Error as e:
            print(f"❌ Error en query: {e}")
            return None

    def insert_data(self):
        """Inserta datos de ejemplo"""
        try:
            print("\n[*] Insertando datos de ejemplo...")

            sql = """
            INSERT INTO usuarios (nombre, email, edad)
            VALUES (%s, %s, %s)
            """

            datos = [
                ('Pedro Martínez', 'pedro@example.com', 30),
                ('Ana Rodríguez', 'ana@example.com', 27),
                ('Luis Fernández', 'luis@example.com', 35),
            ]

            for nombre, email, edad in datos:
                self.cursor.execute(sql, (nombre, email, edad))
                print(f"  ✅ Insertado: {nombre}")

            self.connection.commit()
            print(f"\n✅ {len(datos)} registros insertados")
            return True

        except Error as e:
            print(f"❌ Error: {e}")
            self.connection.rollback()
            return False

    def select_all(self):
        """Obtiene todos los usuarios"""
        try:
            sql = "SELECT id, nombre, email, edad, fecha_registro FROM usuarios ORDER BY id DESC"
            result = self.query(sql)

            if result:
                print(f"\n📊 Usuarios en la base de datos ({len(result)} total):")
                print(f"{'ID':<5} {'Nombre':<20} {'Email':<25} {'Edad':<5} {'Registro':<20}")
                print("-" * 80)

                for row in result:
                    print(f"{row['id']:<5} {row['nombre']:<20} {row['email']:<25} {row['edad']:<5} {row['fecha_registro']}")

            return result
        except Error as e:
            print(f"❌ Error: {e}")
            return None

    def search_by_email(self, email):
        """Busca usuario por email"""
        try:
            sql = "SELECT * FROM usuarios WHERE email = %s"
            self.cursor.execute(sql, (email,))
            result = self.cursor.fetchone()

            if result:
                print(f"\n✅ Usuario encontrado:")
                for key, value in result.items():
                    print(f"   {key}: {value}")
            else:
                print(f"❌ No se encontró usuario con email: {email}")

            return result
        except Error as e:
            print(f"❌ Error: {e}")
            return None

    def close(self):
        """Cierra la conexión"""
        if self.connection:
            self.cursor.close()
            self.connection.close()
            print("\n✅ Conexión cerrada")

# ============================================================================
# EJEMPLOS DE USO
# ============================================================================

def main():
    """Función principal"""

    # Crear conector
    connector = SingleStoreConnector(config)

    # Conectar
    if not connector.connect():
        sys.exit(1)

    # Test conexión
    connector.test_connection()

    # Procesar argumentos
    if len(sys.argv) > 1:
        if sys.argv[1] == '--insert':
            connector.insert_data()
        elif sys.argv[1] == '--query':
            print("\n[*] Ejecutando SELECT...")
        elif sys.argv[1] == '--help':
            print("Uso: python connect_singlestore.py [opción]")
            print("  (sin opción) - Test conexión")
            print("  --insert    - Insertar datos de ejemplo")
            print("  --query     - Ejecutar query")

    # Mostrar todos los datos
    connector.select_all()

    # Ejemplo de búsqueda
    print("\n[*] Buscando usuario específico...")
    connector.search_by_email('maria@example.com')

    # Cerrar conexión
    connector.close()

if __name__ == '__main__':
    main()
