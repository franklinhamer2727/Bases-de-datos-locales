-- ============================================================================
-- INICIALIZACIÓN SINGLESTORE - CREAR USUARIO Y BASE DE DATOS
-- ============================================================================
-- Ejecutar esto DESPUÉS de que el contenedor esté listo

-- 1. Crear base de datos de aplicación
CREATE DATABASE IF NOT EXISTS app_db;

-- 2. Crear usuario de aplicación (no root)
CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY 'app_password_2024';

-- 3. Dar permisos al usuario de aplicación
GRANT ALL PRIVILEGES ON app_db.* TO 'app_user'@'%';
FLUSH PRIVILEGES;

-- 4. Crear usuario de desarrollo (para dev/testing)
CREATE USER IF NOT EXISTS 'dev_user'@'%' IDENTIFIED BY 'dev_password_2024';
GRANT ALL PRIVILEGES ON app_db.* TO 'dev_user'@'%';
FLUSH PRIVILEGES;

-- 5. Tabla de ejemplo para testing
USE app_db;

CREATE TABLE IF NOT EXISTS usuarios (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE,
    edad INT,
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    KEY idx_email (email)
);

-- 6. Insertar datos de prueba
INSERT INTO usuarios (nombre, email, edad) VALUES
('Juan Pérez', 'juan@example.com', 28),
('María García', 'maria@example.com', 32),
('Carlos López', 'carlos@example.com', 25);

-- 7. Ver usuarios creados
SELECT user, host FROM mysql.user WHERE user NOT IN ('mysql.infoschema', 'mysql.session');

-- 8. Ver base de datos
SHOW DATABASES;

-- 9. Ver tablas
SHOW TABLES FROM app_db;

-- 10. Ver datos de ejemplo
SELECT * FROM app_db.usuarios;
