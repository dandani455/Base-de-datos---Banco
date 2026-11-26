<#
  ctl.ps1 - Control del entorno PostgreSQL 16 + pgAdmin 4 (Banco Digital, capa de base de datos).

  SCRIPT CANONICO PARA WINDOWS. PowerShell puro (5.1 o superior); NO requiere Bash, Git Bash, WSL,
  psql local ni Node. Solo necesita Docker Desktop en ejecucion (con "docker compose").

  Este archivo es ASCII a proposito: Windows PowerShell 5.1 lee los .ps1 sin BOM como ANSI y
  corromperia las tildes. No agregar caracteres no ASCII.

  Uso (desde la raiz del repositorio):
      db\ctl.cmd up                  levanta PostgreSQL y pgAdmin (crea db\.env si no existe)
      db\ctl.cmd status              estado de contenedores y direcciones
      db\ctl.cmd apply [NN]          aplica db\sql\*.sql a la BD "banco" (o solo los que empiecen por NN)
      db\ctl.cmd test [NN]           corre las pruebas en la BD desechable "banco_test"
      db\ctl.cmd test -Evidence 00-entorno   ...y guarda la salida en docs\db\evidencias\00-entorno.txt
      db\ctl.cmd psql -Sql "SELECT 1"        ejecuta SQL (sin -Sql abre psql interactivo)
      db\ctl.cmd reset -Yes          RECREA la BD "banco" vacia (destructivo) y elimina banco_test
      db\ctl.cmd logs [db|pgadmin]   ultimas lineas de log
      db\ctl.cmd pgadmin-servers    (re)registra en pgAdmin las conexiones de docker\pgadmin\servers.json
                                     (sin recrear el volumen de pgAdmin)
      db\ctl.cmd down [-Purge]       detiene (con -Purge tambien BORRA los volumenes de datos)
      db\ctl.cmd seed [catalogo|demo]   carga el catalogo / el seed de demostracion (solo sobre un banco VACIO)
      db\ctl.cmd backup [nombre]    respaldo de "banco" en db\backups\banco_<nombre>.dump (+ .huella)
      db\ctl.cmd restore nombre -Yes restaura ese respaldo (la BD actual queda como banco_previo)
      db\ctl.cmd recuperar          termina o deshace una restauracion interrumpida (idempotente)
      db\ctl.cmd descartar-previo    elimina banco_previo

  db\ctl.cmd lanza este script con -ExecutionPolicy Bypass solo para ese proceso, porque la politica
  por defecto de Windows cliente (Restricted) bloquea los .ps1. Alternativa:
      Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'up', 'down', 'status', 'reset', 'apply', 'test', 'psql', 'logs', 'pgadmin-servers', 'seed', 'backup', 'restore', 'recuperar', 'descartar-previo')]
    [string]$Comando = 'help',

    [Parameter(Position = 1)]
    [string]$Objetivo = '',

    [string]$Evidence = '',
    [string]$Sql = '',
    [string]$Base = 'banco',
    [switch]$Purge,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Raiz        = Split-Path -Parent $MyInvocation.MyCommand.Path      # ...\db
$RepoRaiz    = Split-Path -Parent $Raiz
$ComposeFile = Join-Path $Raiz 'compose.dev.yml'
$EnvFile     = Join-Path $Raiz '.env'
$EnvExample  = Join-Path $Raiz '.env.example'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ----------------------------------------------------------------------------- utilidades
function Stop-Ctl {
    param([string]$Mensaje, [int]$Codigo = 1)
    Write-Host "ERROR: $Mensaje" -ForegroundColor Red
    exit $Codigo
}

function Get-EnvConfig {
    $cfg = @{ POSTGRES_USER = 'postgres'; POSTGRES_PASSWORD = ''; DB_PORT = '5433'; PGADMIN_PORT = '5050' }
    if (Test-Path -LiteralPath $EnvFile) {
        foreach ($linea in (Get-Content -LiteralPath $EnvFile)) {
            if ($linea -match '^\s*#') { continue }
            if ($linea -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
        }
    }
    return $cfg
}

# Ejecuta docker capturando stdout+stderr como texto (en 5.1 stderr nativo se vuelve ErrorRecord).
function Invoke-Docker {
    param([string[]]$DockerArgs, [switch]$Silent)
    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lineas = New-Object System.Collections.ArrayList
    $codigo = 1
    try {
        & docker @DockerArgs 2>&1 | ForEach-Object {
            $t = "$_"
            [void]$lineas.Add($t)
            if (-not $Silent) { Write-Host $t }
        }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previo
    }
    return [pscustomobject]@{ Code = $codigo; Lines = @($lineas) }
}

function Invoke-Compose {
    param([string[]]$ComposeArgs, [switch]$Silent)
    $todo = @('compose', '--env-file', $EnvFile, '-f', $ComposeFile) + $ComposeArgs
    return (Invoke-Docker -DockerArgs $todo -Silent:$Silent)
}

# psql dentro del contenedor "db". Los archivos se leen en el contenedor (/work/sql, /work/tests).
function Invoke-Psql {
    param([string]$Database = 'banco', [string[]]$PsqlArgs, [switch]$Silent)
    $cfg = Get-EnvConfig
    $a = @('exec', '-T', 'db', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', $cfg.POSTGRES_USER, '-d', $Database) + $PsqlArgs
    return (Invoke-Compose -ComposeArgs $a -Silent:$Silent)
}

function Assert-Docker {
    $r = Invoke-Docker -DockerArgs @('info', '--format', '{{.ServerVersion}}') -Silent
    if ($r.Code -ne 0) {
        Stop-Ctl 'Docker no responde. Abre Docker Desktop, espera a que diga "Engine running" y repite.'
    }
}

function Assert-EnvFile {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        Copy-Item -LiteralPath $EnvExample -Destination $EnvFile
        Write-Host 'Creado db\.env a partir de db\.env.example (valores de desarrollo local, no secretos).'
    }
}

function Test-DbLista {
    $r = Invoke-Compose -ComposeArgs @('exec', '-T', 'db', 'pg_isready', '-q', '-d', 'banco') -Silent
    return ($r.Code -eq 0)
}

function Assert-DbLista {
    Assert-Docker
    if (-not (Test-DbLista)) { Stop-Ctl 'La base de datos no esta lista. Ejecuta primero: db\ctl.cmd up' }
}

function Get-SqlFiles {
    param([string]$Prefijo)
    $carpeta = Join-Path $Raiz 'sql'
    $f = Get-ChildItem -LiteralPath $carpeta -Filter '*.sql' | Sort-Object Name
    if ($Prefijo) { $f = $f | Where-Object { $_.Name -like "$Prefijo*" } }
    return @($f)
}

# Las pruebas viven en db\tests\run.ps1 (define Invoke-Pruebas; usa las funciones de este script).
. (Join-Path $Raiz 'tests\run.ps1')

# ----------------------------------------------------------------------------- comandos
function Show-Ayuda {
    Write-Host ''
    Write-Host 'ctl - entorno PostgreSQL + pgAdmin (Banco Digital)'
    Write-Host '  up | status | apply [NN] | test [NN] [-Evidence nombre] | psql [-Sql "..."] [-Base nombre]'
    Write-Host '  reset -Yes | logs [servicio] | down [-Purge]'
    Write-Host '  seed [catalogo|demo] | backup [nombre] | restore nombre -Yes | recuperar | descartar-previo'
    Write-Host 'Detalle: docs\db\00-entorno.md'
}

function Invoke-Up {
    Assert-Docker
    Assert-EnvFile
    $cfg = Get-EnvConfig
    $corriendo = Invoke-Compose -ComposeArgs @('ps', '-q') -Silent
    if (-not (@($corriendo.Lines) | Where-Object { $_ -match '\S' })) {
        foreach ($p in @($cfg.DB_PORT, $cfg.PGADMIN_PORT)) {
            $uso = $null
            try { $uso = Get-NetTCPConnection -LocalPort ([int]$p) -State Listen -ErrorAction SilentlyContinue } catch { }
            if ($uso) {
                Stop-Ctl "El puerto $p del host ya esta en uso por otro programa. Cambia DB_PORT/PGADMIN_PORT en db\.env."
            }
        }
    }
    $r = Invoke-Compose -ComposeArgs @('up', '-d', '--quiet-pull', '--wait', '--wait-timeout', '180')
    if ($r.Code -ne 0) { Stop-Ctl "docker compose up fallo (codigo $($r.Code))." }
    Show-Estado
}

function Show-Estado {
    Assert-Docker
    $cfg = Get-EnvConfig
    Invoke-Compose -ComposeArgs @('ps') | Out-Null
    Write-Host ''
    if (Test-DbLista) { Write-Host 'PostgreSQL: LISTO' -ForegroundColor Green } else { Write-Host 'PostgreSQL: NO listo' -ForegroundColor Yellow }
    Write-Host ('pgAdmin 4 : http://localhost:{0}' -f $cfg.PGADMIN_PORT)
    Write-Host ('PostgreSQL: localhost:{0}  (BD banco, usuario {1})' -f $cfg.DB_PORT, $cfg.POSTGRES_USER)
}

function Invoke-PgadminServers {
    Assert-Docker
    # En modo escritorio (SERVER_MODE=False) pgAdmin usa un usuario fijo, no el correo de db\.env.
    $email = 'pgadmin4@pgadmin.org'
    # El contenedor debe estar recreado si cambio el pgpass (compose.dev.yml): "up" lo hace solo.
    $r = Invoke-Compose -ComposeArgs @('exec', '-T', 'pgadmin', '/venv/bin/python3', '/pgadmin4/setup.py', 'load-servers', '/pgadmin4/servers.json', '--user', $email, '--replace')
    if ($r.Code -ne 0) { Stop-Ctl "No se pudieron registrar las conexiones (codigo $($r.Code)). Esta corriendo pgAdmin? (db\ctl.cmd up)" }
    Write-Host 'Conexiones registradas. Recarga pgAdmin (F5) para verlas.' -ForegroundColor Green
}

function Invoke-Down {
    Assert-Docker
    $a = @('down')
    if ($Purge) { $a += '-v' }
    $r = Invoke-Compose -ComposeArgs $a
    if ($r.Code -ne 0) { Stop-Ctl "docker compose down fallo (codigo $($r.Code))." }
    if ($Purge) { Write-Host 'Volumenes eliminados: la proxima vez se crea todo desde cero.' }
}

function Invoke-Apply {
    param([string]$Prefijo)
    Assert-DbLista
    $archivos = Get-SqlFiles -Prefijo $Prefijo
    if ($archivos.Count -eq 0) { Stop-Ctl "No hay archivos en db\sql que coincidan con '$Prefijo'." }
    foreach ($f in $archivos) {
        Write-Host "== Aplicando $($f.Name)" -ForegroundColor Cyan
        $r = Invoke-Psql -Database $Base -PsqlArgs @('-f', "/work/sql/$($f.Name)")
        if ($r.Code -ne 0) { Stop-Ctl "Fallo al aplicar $($f.Name) (codigo $($r.Code))." }
    }
    Write-Host "Listo: $($archivos.Count) archivo(s) aplicado(s) a la BD '$Base'." -ForegroundColor Green
}

function Invoke-Reset {
    Assert-DbLista
    if (-not $Yes) {
        Write-Host 'Esto ELIMINA y recrea la base de datos "banco" (y borra banco_test). Los datos se pierden.' -ForegroundColor Yellow
        $resp = Read-Host 'Escribe "si" para continuar'
        if ($resp -ne 'si') { Stop-Ctl 'Cancelado.' 2 }
    }
    $pasos = @(
        @('postgres', @('-c', 'DROP DATABASE IF EXISTS banco_test WITH (FORCE)')),
        @('postgres', @('-c', 'DROP DATABASE IF EXISTS banco WITH (FORCE)')),
        @('postgres', @('-c', 'CREATE DATABASE banco')),
        @('banco',    @('-f', '/docker-entrypoint-initdb.d/00_bootstrap.sql'))
    )
    foreach ($p in $pasos) {
        $r = Invoke-Psql -Database $p[0] -PsqlArgs $p[1]
        if ($r.Code -ne 0) { Stop-Ctl "reset fallo (codigo $($r.Code))." }
    }
    Write-Host 'BD "banco" recreada vacia. Reconecta pgAdmin (clic derecho en el servidor > Refresh).' -ForegroundColor Green
    Write-Host 'Siguiente paso: db\ctl.cmd apply'
}

function Invoke-PsqlComando {
    Assert-DbLista
    if ($Sql) {
        $r = Invoke-Psql -Database $Base -PsqlArgs @('-c', $Sql)
        if ($r.Code -ne 0) { Stop-Ctl "psql termino con codigo $($r.Code)." $r.Code }
        return
    }
    $cfg = Get-EnvConfig
    & docker compose --env-file $EnvFile -f $ComposeFile exec db psql -X -U $cfg.POSTGRES_USER -d $Base
    exit $LASTEXITCODE
}


# ----------------------------------------------------------------------------- E14: seed, respaldo y restauracion
# La logica vive en db\seed\*.sh y corre DENTRO del contenedor (sh de busybox); aqui solo se invoca y se copian los archivos.
function Invoke-SeedSh {
    param([string]$Script, [string]$ArgsSh)
    $cmd = "tr -d '\r' < /work/seed/$Script | sh -s -- $ArgsSh"
    $r = Invoke-Compose -ComposeArgs @('exec', '-T', 'db', 'sh', '-c', $cmd)
    return $r.Code
}
function Assert-NombreRespaldo {
    param([string]$N)
    if ($N -notmatch '^[A-Za-z0-9._-]+$') { Stop-Ctl "Nombre de respaldo invalido (solo letras, digitos, punto, guion y guion bajo): $N" }
}
function Invoke-Seed {
    Assert-DbLista
    $que = $Objetivo
    if (-not $que) { $que = 'demo' }
    if ($que -ne 'catalogo' -and $que -ne 'demo') { Stop-Ctl 'Uso: db\ctl.cmd seed [catalogo|demo]' }
    $c = Invoke-SeedSh -Script 'sembrar.sh' -ArgsSh $que
    if ($c -ne 0) { Stop-Ctl "seed fallo (codigo $c)." $c }
}
function Invoke-Backup {
    Assert-DbLista
    $n = $Objetivo
    if (-not $n) { $n = (Get-Date).ToString('yyyyMMdd-HHmmss') }
    Assert-NombreRespaldo $n
    $c = Invoke-SeedSh -Script 'respaldo.sh' -ArgsSh "backup /tmp/banco_$n.dump banco"
    if ($c -ne 0) { Stop-Ctl "backup fallo (codigo $c)." $c }
    $dest = Join-Path $Raiz 'backups'
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
    foreach ($ext in @('', '.huella')) {
        $r = Invoke-Compose -ComposeArgs @('cp', "db:/tmp/banco_$n.dump$ext", (Join-Path $dest "banco_$n.dump$ext")) -Silent
        if ($r.Code -ne 0) { Stop-Ctl "No se pudo copiar el respaldo al host (codigo $($r.Code))." }
    }
    Invoke-Compose -ComposeArgs @('exec', '-T', 'db', 'rm', '-f', "/tmp/banco_$n.dump", "/tmp/banco_$n.dump.huella") -Silent | Out-Null
    Write-Host "Respaldo copiado a db\backups\banco_$n.dump (+ .huella). Restaurar: db\ctl.cmd restore $n -Yes" -ForegroundColor Green
}
function Invoke-Restore {
    Assert-DbLista
    $n = $Objetivo
    if (-not $n) { Stop-Ctl 'Uso: db\ctl.cmd restore nombre -Yes' }
    Assert-NombreRespaldo $n
    $arch = Join-Path (Join-Path $Raiz 'backups') "banco_$n.dump"
    if (-not (Test-Path -LiteralPath $arch)) { Stop-Ctl "No existe $arch" }
    if (-not $Yes) { Stop-Ctl "La restauracion REEMPLAZA la BD 'banco' (la actual queda como banco_previo). Repite con -Yes." }
    $r = Invoke-Compose -ComposeArgs @('cp', $arch, "db:/tmp/banco_$n.dump") -Silent
    if ($r.Code -ne 0) { Stop-Ctl "No se pudo copiar el respaldo al contenedor (codigo $($r.Code))." }
    if (Test-Path -LiteralPath "$arch.huella") {
        Invoke-Compose -ComposeArgs @('cp', "$arch.huella", "db:/tmp/banco_$n.dump.huella") -Silent | Out-Null
    }
    $c = Invoke-SeedSh -Script 'respaldo.sh' -ArgsSh "restore /tmp/banco_$n.dump banco --yes"
    Invoke-Compose -ComposeArgs @('exec', '-T', 'db', 'rm', '-f', "/tmp/banco_$n.dump", "/tmp/banco_$n.dump.huella") -Silent | Out-Null
    if ($c -ne 0) { Stop-Ctl "restore fallo (codigo $c); la BD 'banco' no se modifico." $c }
}
function Invoke-Recuperar {
    Assert-DbLista
    $c = Invoke-SeedSh -Script 'respaldo.sh' -ArgsSh 'recuperar banco'
    if ($c -ne 0) { Stop-Ctl "recuperar fallo (codigo $c)." $c }
}
function Invoke-DescartarPrevio {
    Assert-DbLista
    $c = Invoke-SeedSh -Script 'respaldo.sh' -ArgsSh 'descartar banco'
    if ($c -ne 0) { Stop-Ctl "descartar-previo fallo (codigo $c)." $c }
}

# ----------------------------------------------------------------------------- despacho
switch ($Comando) {
    'help'   { Show-Ayuda }
    'up'     { Invoke-Up }
    'status' { Show-Estado }
    'down'   { Invoke-Down }
    'apply'  { Invoke-Apply -Prefijo $Objetivo }
    'reset'  { Invoke-Reset }
    'psql'   { Invoke-PsqlComando }
    'pgadmin-servers' { Invoke-PgadminServers }
    'seed'    { Invoke-Seed }
    'backup'  { Invoke-Backup }
    'restore' { Invoke-Restore }
    'recuperar' { Invoke-Recuperar }
    'descartar-previo' { Invoke-DescartarPrevio }
    'logs'   {
        Assert-Docker
        $a = @('logs', '--tail', '100')
        if ($Objetivo) { $a += $Objetivo }
        Invoke-Compose -ComposeArgs $a | Out-Null
    }
    'test'   {
        Assert-DbLista
        $codigo = Invoke-Pruebas -Prefijo $Objetivo -EvidenciaNombre $Evidence
        exit $codigo
    }
}
