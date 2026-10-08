# Levanta SQL Server y verifica que sa y el usuario de la app entren.
# Uso (desde esta carpeta):  powershell -ExecutionPolicy Bypass -File .\levantar.ps1
# Deja todo lo que muestra tambien en levantar.log
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
Start-Transcript -Path (Join-Path $PSScriptRoot 'levantar.log') -Force | Out-Null

function Ok($m)   { Write-Host "[OK]    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[AVISO] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
function EnvValue($name, $default) {
    $line = Get-Content .env | Where-Object { $_ -match "^\s*$name\s*=" } | Select-Object -First 1
    if ($line) { return ($line -split '=', 2)[1].Trim() } else { return $default }
}
function SetEnvValue($name, $value) {
    $lines = Get-Content .env
    if ($lines -match "^\s*$name\s*=") { $lines = $lines -replace "^\s*$name\s*=.*", "$name=$value" }
    else { $lines += "$name=$value" }
    Set-Content -Path .env -Value $lines -Encoding ASCII
}

# 1. Docker
docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker Desktop no esta corriendo. Abralo, espere "Engine running" y repita.' }
Ok 'Docker Desktop esta corriendo'

# 2. .env
if (-not (Test-Path .env)) { Copy-Item .env.example .env; Ok '.env creado desde .env.example' }
$port = [int](EnvValue 'MSSQL_PORT' '1433')

# 3. Puerto libre en Windows
function PortProblem([int]$p) {
    # Rangos reservados por Hyper-V/WinNAT: Docker no puede publicar ahi.
    $excl = netsh interface ipv4 show excludedportrange protocol=tcp | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(\d+)') { ,@([int]$matches[1], [int]$matches[2]) } }
    foreach ($r in $excl) { if ($p -ge $r[0] -and $p -le $r[1]) { return "reservado por Windows (rango $($r[0])-$($r[1]))" } }
    $l = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($l) {
        $proc = (Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        if ($proc -match 'docker|wslrelay|vpnkit') {
            $owner = docker ps --filter "publish=$p" --format '{{.Names}}'
            if ($owner -and $owner -ne 'sqlserver-dev') { return "usado por el contenedor '$owner'" }
            return $null
        }
        return "usado por el proceso '$proc' (pid $($l.OwningProcess)) - probablemente un SQL Server instalado en Windows"
    }
    return $null
}
$problem = PortProblem $port
if ($problem) {
    Warn "El puerto $port esta $problem."
    foreach ($alt in 14333, 14334, 11433) {
        if (-not (PortProblem $alt)) { $port = $alt; break }
    }
    SetEnvValue 'MSSQL_PORT' $port
    Warn "Se usara el puerto $port (guardado en .env)."
} else { Ok "Puerto $port libre" }

$svc = Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'
if ($svc) { Warn "Hay SQL Server instalado en Windows ($($svc.Name -join ', ')). Al conectar use el puerto $port, no otro." }

# 4. Levantar
Write-Host "`nConstruyendo y levantando (la primera vez descarga ~1.5 GB)..."
docker compose up -d --build
if ($LASTEXITCODE -ne 0) { Fail 'docker compose up fallo (ver mensajes de arriba).' }

# 5. Esperar healthy
Write-Host 'Esperando a que SQL Server quede listo (hasta 5 min)...'
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 5
    $state  = docker inspect sqlserver-dev --format '{{.State.Status}}' 2>$null
    $health = docker inspect sqlserver-dev --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>$null
    $init   = docker logs sqlserver-dev 2>&1 | Select-String '^\[init\]' | Select-Object -Last 1
    if ($init) { Write-Host "  $init" }
    if ($state -ne 'running' -or (docker logs sqlserver-dev 2>&1 | Select-String '\[init\] ERROR')) {
        Write-Host "`n--- ultimas lineas del contenedor ---"
        docker logs --tail 40 sqlserver-dev 2>&1
        Fail 'El contenedor fallo al iniciar (ver lineas [init] ERROR arriba).'
    }
} while ($health -ne 'healthy' -and (Get-Date) -lt $deadline)
if ($health -ne 'healthy') { docker logs --tail 40 sqlserver-dev 2>&1; Fail 'No quedo healthy en 5 minutos.' }
Ok 'Contenedor healthy'

# 6. Verificar logins: dentro del contenedor y entrando por el puerto publicado
docker exec sqlserver-dev verificar.sh
if ($LASTEXITCODE -ne 0) { Fail 'Algun login fallo dentro del contenedor (ver arriba).' }
docker exec sqlserver-dev verificar.sh host.docker.internal $port
if ($LASTEXITCODE -ne 0) { Fail "Algun login fallo entrando por el puerto $port publicado (ver arriba)." }
Ok 'sa y el usuario de la app entran (directo y por el puerto publicado)'

# 7. Verificar desde Windows
$tcp = Test-NetConnection -ComputerName localhost -Port $port -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) { Ok "localhost:$port responde desde Windows" } else { Fail "localhost:$port no responde desde Windows" }

$appUser = EnvValue 'APP_USER' 'datahub'; $appDb = EnvValue 'APP_DB' 'GNBPE_DATAHUB'
Write-Host @"

================ LISTO ================
DBeaver / SSMS / Azure Data Studio (desde Windows):
  Host: localhost      Puerto: $port
  Usuario admin: sa            (password: MSSQL_SA_PASSWORD del .env)
  Usuario app:   $appUser       (password: APP_PASSWORD del .env)  Base: $appDb
  Driver: marcar "Trust Server Certificate" = true
CloudBeaver (http://localhost:8978): host host.docker.internal, puerto $port
=======================================
"@
Stop-Transcript | Out-Null
