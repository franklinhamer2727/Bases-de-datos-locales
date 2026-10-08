-- Base de la aplicacion + login propio (NO se usa 'sa' desde Airflow/ETL).
-- Idempotente: se ejecuta en CADA arranque y repara lo que falte o este roto.
SET NOCOUNT ON;
GO

IF DB_ID(N'$(APP_DB)') IS NULL
BEGIN
    PRINT 'creando base $(APP_DB)';
    CREATE DATABASE [$(APP_DB)];
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(APP_USER)')
BEGIN
    PRINT 'creando login $(APP_USER)';
    CREATE LOGIN [$(APP_USER)]
        WITH PASSWORD = N'$(APP_PASSWORD)',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF,
             DEFAULT_DATABASE = [$(APP_DB)];
END
ELSE
BEGIN
    -- Solo se cambia la password si NO coincide con la del .env. Re-aplicar la
    -- misma password en cada arranque puede ser rechazado por la politica de
    -- passwords y tumbaria el contenedor.
    IF PWDCOMPARE(N'$(APP_PASSWORD)',
                  (SELECT password_hash FROM sys.sql_logins WHERE name = N'$(APP_USER)')) = 0
    BEGIN
        PRINT 'actualizando password de $(APP_USER) (cambio en .env)';
        ALTER LOGIN [$(APP_USER)] WITH CHECK_POLICY = OFF;   -- evita rechazo por historial
        ALTER LOGIN [$(APP_USER)] WITH PASSWORD = N'$(APP_PASSWORD)';
        ALTER LOGIN [$(APP_USER)] WITH CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
    END
    ALTER LOGIN [$(APP_USER)] WITH DEFAULT_DATABASE = [$(APP_DB)];
    ALTER LOGIN [$(APP_USER)] ENABLE;
END
GO

-- Por si quedo bloqueado tras intentos fallidos con CHECK_POLICY.
-- (apagar y volver a encender CHECK_POLICY reinicia el contador de intentos)
IF LOGINPROPERTY(N'$(APP_USER)', 'IsLocked') = 1
BEGIN
    PRINT 'desbloqueando login $(APP_USER)';
    ALTER LOGIN [$(APP_USER)] WITH CHECK_POLICY = OFF;
    ALTER LOGIN [$(APP_USER)] WITH CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
END
GO

GRANT CONNECT SQL TO [$(APP_USER)];
GO

USE [$(APP_DB)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(APP_USER)')
BEGIN
    CREATE USER [$(APP_USER)] FOR LOGIN [$(APP_USER)];
END
ELSE
BEGIN
    -- Repara usuario "huerfano" (SID distinto al del login, p.ej. tras
    -- restaurar un backup): sin esto el login entra pero no "ve" la base.
    ALTER USER [$(APP_USER)] WITH LOGIN = [$(APP_USER)];
END
GO

GRANT CONNECT TO [$(APP_USER)];
GO

-- db_owner sobre SU base, nada fuera de ella. Las tablas de control las crea
-- despues sql/bt2sql/20_bt2sql_control_sqlserver.sql.
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals u ON u.principal_id = rm.member_principal_id
    WHERE r.name = N'db_owner' AND u.name = N'$(APP_USER)'
)
    ALTER ROLE db_owner ADD MEMBER [$(APP_USER)];
GO
