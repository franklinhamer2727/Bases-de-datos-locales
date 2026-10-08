# Diagnostico de SQL Server en Docker. Ejecutar desde la carpeta sqlserver:
#   powershell -ExecutionPolicy Bypass -File .\diagnostico.ps1
# Genera diagnostico.txt (no incluye passwords).
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$out = Join-Path $PSScriptRoot 'diagnostico.txt'
function Sec($t) { "`n===== $t =====" }

& {
    Sec 'fecha'; Get-Date
    Sec 'docker'; docker version --format 'server {{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}' 2>&1
    Sec 'docker compose ps -a'; docker compose ps -a 2>&1
    Sec 'todos los contenedores'; docker ps -a --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>&1
    Sec 'estado sqlserver-dev'
    docker inspect sqlserver-dev --format 'Status={{.State.Status}} Restarts={{.RestartCount}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Health={{if .State.Health}}{{.State.Health.Status}}{{end}} Error={{.State.Error}}' 2>&1
    Sec 'logs sqlserver-dev (ultimas 150 lineas)'; docker logs --tail 150 sqlserver-dev 2>&1
    Sec 'quien escucha en el puerto 1433 de Windows'
    Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        '{0}:{1} pid={2} proceso={3}' -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $p.ProcessName
    }
    Sec 'servicios SQL Server instalados en Windows'
    Get-Service -Name 'MSSQL*', 'SQLBrowser', 'SQLAgent*' -ErrorAction SilentlyContinue | Format-Table -AutoSize Name, Status, StartType | Out-String
    Sec 'puertos reservados por Hyper-V / WinNAT (si 1433 cae en un rango, Docker no puede publicarlo)'
    netsh interface ipv4 show excludedportrange protocol=tcp
    Sec 'Test-NetConnection localhost:1433'
    Test-NetConnection -ComputerName localhost -Port 1433 -WarningAction SilentlyContinue | Select-Object TcpTestSucceeded, RemoteAddress | Out-String
    Sec 'login sa dentro del contenedor'
    docker exec sqlserver-dev bash -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -W -Q "SET NOCOUNT ON; SELECT @@VERSION; SELECT name, is_disabled, default_database_name FROM sys.sql_logins; SELECT name FROM sys.databases"' 2>&1
    Sec 'login de la app dentro del contenedor'
    docker exec sqlserver-dev bash -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U "$APP_USER" -P "$APP_PASSWORD" -d "$APP_DB" -W -Q "SELECT SUSER_NAME() AS usuario, DB_NAME() AS base"' 2>&1
    Sec 'errorlog: ultimos fallos de login (el "Reason" dice la causa)'
    docker exec sqlserver-dev bash -c 'grep -a -A1 "Login failed" /var/opt/mssql/log/errorlog | tail -20' 2>&1
    Sec 'volumenes'; docker volume ls --format '{{.Name}}' 2>&1 | Select-String 'sql|mssql'
    Sec '.env (sin passwords)'; Get-Content .env | Where-Object { $_ -notmatch 'PASSWORD' }
    Sec '.wslconfig'; Get-Content "$env:USERPROFILE\.wslconfig" -ErrorAction SilentlyContinue
} *>&1 | Out-File -FilePath $out -Encoding utf8 -Width 300

Write-Host "Listo: $out"
