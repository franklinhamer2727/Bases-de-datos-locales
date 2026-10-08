-- Base de la aplicacion + login propio. NO se usa 'sa' desde Airflow/ETL: sa
-- es sysadmin de toda la instancia; una credencial de ETL no tiene por que
-- poder borrar otras bases.
-- Idempotente: se ejecuta en cada arranque del contenedor.
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
    -- Mantiene la password sincronizada con el .env si se cambio despues.
    ALTER LOGIN [$(APP_USER)]
        WITH PASSWORD = N'$(APP_PASSWORD)',
             DEFAULT_DATABASE = [$(APP_DB)];
    ALTER LOGIN [$(APP_USER)] ENABLE;
END
GO

USE [$(APP_DB)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(APP_USER)')
    CREATE USER [$(APP_USER)] FOR LOGIN [$(APP_USER)];
GO

-- db_owner sobre SU base, nada fuera de ella. Las tablas de control las crea
-- despues sql/bt2sql/20_bt2sql_control_sqlserver.sql.
IF IS_ROLEMEMBER(N'db_owner', N'$(APP_USER)') = 0
    ALTER ROLE db_owner ADD MEMBER [$(APP_USER)];
GO
