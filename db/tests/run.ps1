<#
  run.ps1 - Runner de pruebas SQL (PowerShell puro, ASCII).

  No se ejecuta solo: ctl.ps1 lo carga (dot-source) y llama a Invoke-Pruebas. Si lo ejecutas directo
  ("db\tests\run.ps1 [NN]") simplemente delega en "ctl.ps1 test [NN]".

  Que hace Invoke-Pruebas:
    1. Recrea la BD desechable "banco_test" (zona America/Bogota, search_path public,tests).
    2. Aplica db\sql\*.sql en orden (el mismo SQL que se aplica a "banco").
    3. Carga helpers.sql SOLO en banco_test.
    4. Ejecuta cada db\tests\*.test.sql con psql -v ON_ERROR_STOP=1 dentro del contenedor.
       Cada asercion correcta imprime "NOTICE: PASS: etiqueta"; una falla lanza "FAIL: ...".
    5. Comprueba que los helpers NO existen en la BD "banco".
    6. Imprime "N passed, M failed" y devuelve 0 (todo bien) o 1 (alguna falla).
#>
if ($MyInvocation.InvocationName -ne '.') {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'ctl.ps1') test @args
    exit $LASTEXITCODE
}

# Elimina el rol-sonda ledger_probe (conexiones reales de E2). Es un rol GLOBAL del cluster: se garantiza su
# eliminacion al empezar y al terminar (try/finally), pase lo que pase en las pruebas.
function Remove-SondaLedger {
    $r = Invoke-Psql -Database 'postgres' -PsqlArgs @('-q', '-f', '/work/tests/reales/limpiar_sonda.sql') -Silent
    return ($r.Code -eq 0)
}

function Invoke-Pruebas {
    param([string]$Prefijo = '', [string]$EvidenciaNombre = '')
    [void](Remove-SondaLedger)
    try {
        return (Invoke-PruebasCore -Prefijo $Prefijo -EvidenciaNombre $EvidenciaNombre)
    } finally {
        [void](Remove-SondaLedger)
    }
}

function Invoke-PruebasCore {
    param([string]$Prefijo = '', [string]$EvidenciaNombre = '')

    $log = New-Object System.Collections.ArrayList
    $cuenta = @{ Passed = 0; Failed = 0 }
    function Write-Log {
        param([string]$Texto, [string]$Color = '')
        if ($Color) { Write-Host $Texto -ForegroundColor $Color } else { Write-Host $Texto }
        [void]$log.Add($Texto)
    }

    $cfg = Get-EnvConfig
    $inicio = Get-Date

    # --- cabecera (queda en la evidencia)
    $pgv = Invoke-Psql -Database 'postgres' -PsqlArgs @('-At', '-c', 'SELECT version()') -Silent
    $dkv = Invoke-Docker -DockerArgs @('--version') -Silent
    $rama = ''
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try { $rama = (& git -C $RepoRaiz rev-parse --abbrev-ref HEAD 2>$null) } catch { $rama = '' }
    }
    Write-Log '=== Banco Digital - pruebas de la capa de base de datos ==='
    Write-Log ("Fecha     : {0}" -f $inicio.ToString('yyyy-MM-dd HH:mm:ss zzz'))
    Write-Log ("Docker    : {0}" -f ($dkv.Lines -join ' '))
    Write-Log ("PostgreSQL: {0}" -f (($pgv.Lines | Where-Object { $_ -match 'PostgreSQL' } | Select-Object -First 1)))
    if ($rama) { Write-Log ("Rama git  : {0}" -f $rama) }
    if ($Prefijo) { Write-Log ("Filtro    : pruebas que empiezan por '{0}'" -f $Prefijo) }
    Write-Log ''

    # --- 1. BD desechable
    Write-Log '== Preparando banco_test' 'Cyan'
    $prep = @(
        @('-c', 'DROP DATABASE IF EXISTS banco_test WITH (FORCE)'),
        @('-c', 'CREATE DATABASE banco_test'),
        @('-c', "ALTER DATABASE banco_test SET timezone TO 'America/Bogota'"),
        @('-c', 'ALTER DATABASE banco_test SET search_path TO public, tests')
    )
    foreach ($p in $prep) {
        $r = Invoke-Psql -Database 'postgres' -PsqlArgs $p -Silent
        if ($r.Code -ne 0) {
            $r.Lines | ForEach-Object { Write-Log "   $_" 'Red' }
            Write-Log 'No se pudo preparar banco_test.' 'Red'
            return 1
        }
    }

    # --- 2. SQL del proyecto
    foreach ($f in (Get-SqlFiles -Prefijo '')) {
        $r = Invoke-Psql -Database 'banco_test' -PsqlArgs @('-q', '-f', "/work/sql/$($f.Name)") -Silent
        if ($r.Code -ne 0) {
            $r.Lines | ForEach-Object { Write-Log "   $_" 'Red' }
            Write-Log "FALLO al aplicar $($f.Name) en banco_test." 'Red'
            return 1
        }
        Write-Log "   aplicado $($f.Name)"
    }

    # --- 3. helpers (solo banco_test)
    $r = Invoke-Psql -Database 'banco_test' -PsqlArgs @('-q', '-f', '/work/tests/helpers.sql') -Silent
    if ($r.Code -ne 0) {
        $r.Lines | ForEach-Object { Write-Log "   $_" 'Red' }
        Write-Log 'FALLO al cargar helpers.sql.' 'Red'
        return 1
    }
    Write-Log '   cargado helpers.sql (solo en banco_test)'
    $r = Invoke-Psql -Database 'banco_test' -PsqlArgs @('-q', '-f', '/work/tests/harness.sql') -Silent
    if ($r.Code -ne 0) {
        $r.Lines | ForEach-Object { Write-Log "   $_" 'Red' }
        Write-Log 'FALLO al cargar harness.sql.' 'Red'
        return 1
    }
    Write-Log '   cargado harness.sql (funciones arnes, solo en banco_test)'
    Write-Log ''

    # --- 4. pruebas
    $pruebas = @(Get-ChildItem -LiteralPath (Join-Path $Raiz 'tests') -Filter '*.test.sql' | Sort-Object Name)
    if ($Prefijo) { $pruebas = @($pruebas | Where-Object { $_.Name -like "$Prefijo*" }) }
    $hayReales = @(Get-ChildItem -LiteralPath (Join-Path $Raiz 'tests\reales') -Filter '*.sh' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '^[0-9][0-9]_' -and (-not $Prefijo -or $_.Name -like "$Prefijo*") }).Count
    if ($pruebas.Count -eq 0 -and $hayReales -eq 0) {
        Write-Log "No hay pruebas que coincidan con '$Prefijo'." 'Red'
        return 1
    }
    foreach ($t in $pruebas) {
        Write-Log "== $($t.Name)" 'Cyan'
        $r = Invoke-Psql -Database 'banco_test' -PsqlArgs @('-q', '-t', '-A', '-f', "/work/tests/$($t.Name)") -Silent
        foreach ($l in $r.Lines) {
            if ($l -match 'NOTICE:\s+PASS:\s*(.*)$') {
                $cuenta.Passed++
                Write-Log ("   ok    {0}" -f $Matches[1].Trim()) 'Green'
            }
        }
        if ($r.Code -ne 0) {
            $cuenta.Failed++
            foreach ($l in $r.Lines) {
                if ($l -notmatch 'NOTICE:\s+PASS:' -and $l -match '\S') { Write-Log "   $l" 'Red' }
            }
            Write-Log "   FALLO: $($t.Name) (codigo $($r.Code))" 'Red'
        }
    }

    # --- 4b. pruebas con CONEXIONES REALES y CONCURRENCIA: scripts sh que corren DENTRO del contenedor
    #         (psql con TCP + contrasena, procesos en paralelo). Imprimen "PASS: etiqueta" / "FAIL: ...".
    $reales = @(Get-ChildItem -LiteralPath (Join-Path $Raiz 'tests\reales') -Filter '*.sh' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9][0-9]_' } | Sort-Object Name)
    if ($Prefijo) { $reales = @($reales | Where-Object { $_.Name -like "$Prefijo*" }) }
    foreach ($t in $reales) {
        Write-Log "== reales/$($t.Name)" 'Cyan'
        $r = Invoke-Compose -ComposeArgs @('exec', '-T', 'db', 'sh', '-c', "tr -d '\r' < /work/tests/reales/$($t.Name) | sh -s") -Silent
        $falla = $false
        foreach ($l in $r.Lines) {
            if ($l -match '^PASS:\s*(.*)$') {
                $cuenta.Passed++
                Write-Log ("   ok    {0}" -f $Matches[1].Trim()) 'Green'
            } elseif ($l -match '^FAIL:') {
                $falla = $true
                Write-Log "   $l" 'Red'
            } elseif ($l -match '\S' -and $l -notmatch '^RESUMEN') {
                Write-Log "   $l"
            }
        }
        if ($r.Code -ne 0 -or $falla) {
            $cuenta.Failed++
            Write-Log "   FALLO: reales/$($t.Name) (codigo $($r.Code))" 'Red'
        }
    }

    # --- 5. aislamiento de los helpers
    Write-Log ''
    Write-Log '== aislamiento' 'Cyan'
    $sonda = Invoke-Psql -Database 'postgres' -PsqlArgs @('-At', '-c', "SELECT to_regrole('ledger_probe') IS NULL") -Silent
    if ($sonda.Code -eq 0 -and (@($sonda.Lines) -contains 't')) {
        $cuenta.Passed++
        Write-Log '   ok    el rol-sonda ledger_probe NO existe tras las pruebas reales' 'Green'
    } else {
        $cuenta.Failed++
        Write-Log '   FALLO: el rol ledger_probe sigue existiendo' 'Red'
    }
    $iso = Invoke-Psql -Database 'banco' -PsqlArgs @('-At', '-c', "SELECT to_regnamespace('tests') IS NULL") -Silent
    if ($iso.Code -eq 0 -and (@($iso.Lines) -contains 't')) {
        $cuenta.Passed++
        Write-Log '   ok    los helpers (esquema tests) NO existen en la BD banco' 'Green'
    } else {
        $cuenta.Failed++
        Write-Log '   FALLO: el esquema tests existe en la BD banco (o no se pudo comprobar)' 'Red'
    }

    # --- 6. resumen
    Write-Log ''
    $resumen = "{0} passed, {1} failed" -f $cuenta.Passed, $cuenta.Failed
    if ($cuenta.Failed -gt 0) { Write-Log $resumen 'Red' } else { Write-Log $resumen 'Green' }
    Write-Log ("Duracion  : {0:N1} s" -f ((Get-Date) - $inicio).TotalSeconds)

    if ($EvidenciaNombre) {
        $dir = Join-Path $RepoRaiz 'docs\db\evidencias'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $destino = Join-Path $dir ($EvidenciaNombre + '.txt')
        $texto = ($log -join "`n") + "`n"
        [System.IO.File]::WriteAllText($destino, $texto, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Evidencia guardada en $destino"
    }

    if ($cuenta.Failed -gt 0) { return 1 }
    return 0
}
