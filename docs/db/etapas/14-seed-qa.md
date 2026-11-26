# Etapa 14 — Seed y QA (catálogo, datos de demostración, respaldo/restauración, runbook y aceptación) · paquete de entrega

**Estado (2026-11-25): IMPLEMENTADA con las 4 correcciones de tu auditoría aplicadas (§10); verificación PARCIAL: faltan la suite completa y la aplicación desde cero con los scripts corregidos (§10.4). PENDIENTE DE TU APROBACIÓN. No se da por completada hasta tu aprobación explícita.** Diseño v1 aprobado (`14-seed-qa-diseno.md`; D-E14-1 a D-E14-7, D-E14-D1/D2/D3) con tus tres condiciones: protección del respaldo/restauración, limpieza del esquema temporal `seed` y reproducibilidad funcional de la demostración. **Sin commits.** `db/sql/` y todo objeto de E1–E13 **intactos** (131 funciones, `banco_app` = 40); `front/` y backend intactos (el backend de `origin/main` es un borrador temporal y no se usó como autoridad). E15 no existe; no se inició nada más.

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| Catálogo provisional (3 CDT, 4 productos de crédito; idempotente) | `db/seed/00_catalogo.sql` |
| Funciones solo-seed (esquema **temporal** `seed`: se crea y se elimina siempre) | `db/seed/10_funciones_seed.sql` |
| Historia de demostración con funciones **reales** (una sola transacción) | `db/seed/20_demo.sql` |
| Ejecutores dentro del contenedor | `db/seed/sembrar.sh` (catálogo/demo + limpieza) y `db/seed/respaldo.sh` (backup/restore protegidos) |
| Tooling de E0 (únicos cambios fuera de `db/seed`) | `db/compose.dev.yml` (+1 montaje `./seed:/work/seed:ro` en `db` y `pgadmin`), `db/ctl.ps1` y `db/ctl.sh` (`seed`, `backup`, `restore`, `descartar-previo`), `db/tests/mutaciones/mutaciones.sh` (bloque E14 + una mejora del mensaje de `detectar`, ya anotada en E13) |
| Carpeta de respaldos locales (no versionados) | `db/backups/.gitignore` (+ `banco_inicial.dump` generado en las pruebas) |
| Pruebas nuevas | `reales/57_seed` (54), `reales/58_respaldo` (27), `reales/59_volumen` (9) = **90** |
| Mutaciones | `mutaciones.sh`: **M468–M493** (25; M486 se descartó) |
| Documentos | este paquete, `14-resumen-para-juan.md`, `docs/db/runbook-demo.md` |
| Evidencias | `docs/db/evidencias/14-*.txt`, `14-pgadmin-demo.sql` y su salida, `git_status_e14.txt` |

## 2. Cómo funciona

```
ctl seed  → sembrar.sh demo
   1. banco con datos (usuarios o libro)?  → se NIEGA (código 2), no crea nada
   2. 00_catalogo.sql  (upsert por nombre)            3. trap: DROP SCHEMA seed SIEMPRE (éxito, error o interrupción)
   4. 10_funciones_seed.sql  → esquema seed           5. 20_demo.sql  (UNA transacción; setseed(0.2026)):
        admin1 → mora 30 % → reloj R-120 → 10 clientes (registrar_usuario + identidad fija + verificar_correo) → R-119 referida
        → R-118 bonos de bienvenida (admin_ajustar_balance) → bolsillos → ~21 envíos/recibos → CDT 90 d (cierra) y 180 d (activo)
        → Libre inversión (descuento automático) y Vehículo (sin él: mora) → R-10 bloqueo → vuelta al reloj REAL
      → CALL sp_avanzar_todos()  (E13: lo guardado al día) → DROP SCHEMA seed
ctl backup N → pg_dump -Fc + manifiesto (huella, usuarios, patas, eventos, integridad) → db\backups
ctl restore N -Yes → valida archivo+manifiesto → restaura en BD de paso → VERIFICA huella e integridad → intercambia; la anterior queda como banco_previo
```

* **Identidad fija:** `registrar_usuario` genera username/cuenta al azar y la guardia hace inmutable `numero_cuenta`; `seed.fijar_identidad` (solo superusuario, con `session_replication_role = replica` que **restablece siempre**) lo fija justo después de registrar, **antes** de `verificar_correo` (el bono del referidor guarda la cuenta del nuevo usuario) y se **niega** si el cliente ya tiene operaciones; verifica que ningún asiento mencione el número viejo.
* **Condición 1 — protección del respaldo/restauración:** exige `--yes`; valida que el archivo exista, sea un volcado legible, **sea de este banco** (tablas `usuario`, `transaccion`, `reloj`, `audit.evento`) y traiga **manifiesto**; restaura en una BD de paso y **compara la huella y la integridad** antes de tocar nada; solo entonces intercambia nombres (con reintentos y cierre de conexiones); la BD anterior se **conserva** como `banco_previo`; nunca actúa sobre `banco_test`, `*_previo`, `*_restaurando` ni nombres ajenos. Si algo falla, **`banco` no se modifica** y la BD de paso se elimina.
* **Condición 2 — limpieza de `seed`:** el esquema no existe en el banco terminado; `sembrar.sh` lo elimina con `trap` en éxito, error o interrupción; la historia es **una sola transacción** (un fallo no deja usuarios ni reloj movido). Probado con un fallo a mitad y con un fallo al crear las funciones.
* **Condición 3 — reproducibilidad funcional:** `setseed` hace deterministas los montos aleatorios; dos siembras en bases distintas dan el **mismo estado funcional** (usuarios, cuentas, códigos fijos, libro como multiconjunto por día con montos/notas/contrapartes, bolsillos, CDT y créditos), con UUID distintos; y **restaurar y repetir el mismo adelanto** da el mismo resultado.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`ctl.sh test --evidence 14-seed-qa`) | **3252 aprobadas, 0 fallidas** (E13 con su corrección: 3162; **+90**, 0 menos) |
| Pruebas nuevas | `57_seed` **54**, `58_respaldo` **27**, `59_volumen` **9** (todas en **bases aisladas** `banco_seed_*`, `banco_rs*`, `banco_vol`; no tocan `banco` ni `banco_test`) |
| Mutaciones M468–M493 | **25 de 25 detectadas** (`14-seed-qa-mutaciones.txt`). La 1.ª corrida dio 24/25 (`…-1a-corrida.txt`): **M490** (restore sin cerrar conexiones) sobrevivió porque la conexión abierta de la prueba B7 duraba 30 s y terminaba antes que los reintentos; B7 ahora usa una conexión de 600 s que solo cierra el *restore*; reejecutadas las 25 → 25/25. Sin equivalentes. |
| Regresión de mutaciones E1–E13 | **No se ejecutó**: E14 no modifica `db/sql` ni ningún objeto de E1–E13 (solo tooling); el diseño aprobado lo establece así. |
| `reset` + 3 × `apply` + seed + backup + restore **desde cero con `ctl.ps1`** (Windows PowerShell 5.1) | `14-seed-qa-aplicacion.txt`: 27 archivos por pasada sin errores; seed → 12 usuarios, 11 cuentas, integridad ok, 0 defensas caídas, reloj real, 0 patas futuras, esquema `seed` eliminado, 3 CDT y 4 productos; **segundo seed se niega (código 2)**; backup `inicial`; alteración (+10 días, `sp_avanzar_todos`, 337 patas, reloj manual); `restore` sin `-Yes` se niega; `restore -Yes` → 324 patas, reloj real, integridad ok, `banco_previo` creado y luego descartado; restaurar de nuevo = misma huella. Además `ctl.sh` (Git Bash) probado con `seed`, `backup`, `restore` y `descartar-previo`. |
| Apagón de la BD (`stop db` → `start db`) | `14-apagon-bd.txt`: misma huella, 12 usuarios, 324 patas, `integridad_ok`, sin pasos extra; volumen `pgdata` conservado; con la BD detenida la conexión falla (lo que el backend traduce a 503) |
| Volumen acotado | `14-volumen.txt`: 300 clientes y 15.556 patas por funciones reales (29 s); búsqueda de admin 12 ms; última página de `transaccion` 138 ms; historial de 50 en 22 ms por la conexión real de `banco_app` (índice `ix_transaccion_cuenta_orden`); `sp_avanzar_todos` con trabajo en 300 cuentas: **2 s**, 0 errores; idempotente |
| Demo de pgAdmin | `14-pgadmin-demo.sql` + salida real `14-pgadmin-demo-salida.txt` (todo en `BEGIN … ROLLBACK`) |
| Estado final de `banco` | Limpia: 0 usuarios, reloj real, sin esquema `seed` ni `tests`, catálogo vacío (el catálogo y los datos llegan con `ctl seed`). |

Qué cubre cada archivo nuevo:
* **57** — catálogo (valores del spec/mock, topes y regla de edad, idempotencia, la recarga restaura lo editado); seed (12 usuarios, identidades fijas, clave `Banco2026` por `crypt()`, referido y bono con la cuenta fija, 2 bolsillos, 2 CDT activo/cerrado, 2 créditos de productos distintos con y sin mora, ≥ 20 envíos/recibos, `bloqueado1` con el mensaje exacto, reloj real, 0 patas futuras, integridad, 1 evento de mantenimiento e idempotencia, auditoría de acciones admin, 131 funciones y `banco_app` = 40); protecciones (se niega sobre un banco con datos; un fallo a mitad no deja nada y elimina `seed`; las funciones solo-seed rechazan identidad tardía, username inválido y admin tardío); reproducibilidad (D); **recorrido de `banco_app` por TCP** sobre el seed (login, perfil, dashboard, historial, balance, CDT, créditos, catálogo, simulaciones, reglas del contrato, `bloqueado1`, `admin1`, `Acceso denegado`) y el ítem del §8 del **reloj +30 días** (el dashboard ya trae el interés cobrado).
* **58** — backup (archivo, manifiesto, huella reproducible, bases no permitidas); restore (sin `--yes` no hace nada, huella e integridad idénticas, `_previo`, conexión abierta, descartar); protecciones (archivo corrupto, sin manifiesto, manifiesto que no coincide, volcado de otra BD, nombres no permitidos, archivo inexistente); repetir la demostración y alternativa de plantilla.
* **59** — carga con funciones reales, búsqueda, página grande, historial con su plan de índice, `sp_avanzar_todos` con trabajo real a escala e idempotencia.

## 4. Matriz de aceptación del §8 del contrato

| Ítem del checklist | Dónde se prueba | Comando para reproducir |
|---|---|---|
| Cada función del §3 tiene test SQL que verifica nombres de campo y tipos de la salida | `67_contrato` (las 26 funciones de cliente), `68`–`71` (12 `admin_*` y Control), `72`/`reales/56` (mantenimiento, sin contrato) | `ctl.sh test 67` · `ctl.sh test 6` · `ctl.sh test 7` |
| Dinero como número, fechas ISO, listas `[]`, ningún `numeric` como string | `67_contrato`; `precision.test.mjs` (`10-precision.txt`) | `ctl.sh test 67` |
| Todos los mensajes del §6 con `P0001` y texto exacto | `67_contrato` (catálogo byte a byte) y ≥ 3 pruebas por mensaje en E4–E12; **E14/57** E8/E10/E12 los comprueba sobre los datos sembrados | `ctl.sh test` |
| Con el reloj +30 días, `vista_dashboard` ya trae el interés de bolsillos/CDT | `54_devengo`, `65`/`66`, `reales/45`/`51` y **`reales/57` E13 sobre el seed** | `ctl.sh test 57` |
| Con 30 años y un crédito de 360 cuotas, `avanzar_hasta` < 5 s | `54_devengo`, `57_creditos_calculo`, `58_creditos`, `62_cobro_automatico` | `ctl.sh test 62` |
| `admin_tabla('usuario', 1)` nunca devuelve un hash real; `admin_esquema` incluye la FK `usuario.referido_por` | `71_control`, `reales/55`, y `reales/57` E11 sobre el seed | `ctl.sh test 71` |
| El backend puede reemplazar el mock endpoint por endpoint | **Fuera de la BD** (Juan). La BD entrega: tabla maestra (`10-resumen-para-juan.md`), resúmenes E4–E13, seed con los usuarios del contrato y `14-resumen-para-juan.md` | — |

## 5. Decisiones aprobadas y cómo se reflejan

| ID | Cómo quedó |
|---|---|
| D-E14-1 | Catálogo, seed, respaldo, runbook, matriz y QA fuera de `db/sql`; `sp_cargar_demo` queda sustituido por `ctl seed demo`. |
| D-E14-2 | Esquema temporal `seed` (eliminado siempre); identidad con `session_replication_role = replica` justo tras `registrar_usuario`. |
| D-E14-3 | `setseed(0.2026)`; solo sobre banco vacío; el catálogo se carga aparte e idempotente. |
| D-E14-4 | Incluye un crédito *Vehículo* sin descuento automático (**mora** visible) y un referido con bono. |
| D-E14-5 | `pg_dump -Fc` + `pg_restore` por `ctl backup/restore`; la plantilla (`CREATE DATABASE … TEMPLATE`) probada como alternativa (D3 de la prueba 58). |
| D-E14-6 | **No** se añadió ninguna guarda de «un solo adelanto» (P-DEMO-1/2): política + restaurar. |
| D-E14-7 | `reales/59_volumen` (300 clientes, 15.556 patas). |
| **D-E14-D1/D2/D3 (equipo)** | Catálogo provisional del spec con tasas del mock (CDT 90/180/360 d, mínimo $100.000); clave `Banco2026` y datos ficticios; mora 30 % solo en el seed. Todo editable en `db/seed/`. |

## 6. Desviaciones, hallazgos y límites (sin ocultar nada)

1. **Más aserciones que el estimado:** +90 (≈ +77): `58` tiene 27 (≈ 12) porque cada protección del restore se prueba por separado.
2. **Historia con 21 envíos/recibos, no 18:** el diseño exigía «≥ 20 filas visibles»; se añadieron 3 transferencias de `jperez483` para que los **grupos ENVIO/RECIBO** sean ≥ 20 (el historial visible ya tiene > 50 filas con los intereses).
3. **`admin_bloquear` exige el uuid** del usuario (no acepta el username como `admin_ajustar_balance`): el seed lo pasa como `bl::text`.
4. **El orden de las filas de interés de bolsillos dentro del mismo día depende de los uuid:** la huella funcional (condición 3) compara el libro como **multiconjunto por día**, no por orden físico.
5. **Hallazgo — índices GIN `pg_trgm`/`unaccent` de la búsqueda de admin no existen:** E1 los difirió a E11 y E11 no los creó (`04_indices.sql` solo lo menciona). Con 300 clientes la búsqueda tarda ~12 ms; con decenas de miles convendría crearlos. **No se creó** (requiere un script nuevo en `db/sql`, fuera de la restricción de E14); queda para tu decisión.
6. **Mensajes de `ctl.ps1`/`ctl.sh` para `restore`:** el texto de respaldo.sh menciona `--yes` mientras el comando de Windows usa `-Yes` (la prueba lo muestra: «Repite con -Yes» en `ctl.ps1`, «--yes» en `ctl.sh`/`respaldo.sh`).
7. **Pruebas de tiempo** (`59`: búsqueda < 2 s, última página < 2 s, historial < 1 s, cierre < 120 s) son cotas amplias; en un equipo muy cargado podrían ser sensibles. Cerca de la medianoche de Bogotá la huella funcional compara desfases de días respecto del hoy: repetir si falla una prueba aislada.
8. **El seed no es idempotente a propósito** (solo banco vacío); si se interrumpe tras la historia, `banco` queda con datos: `ctl reset -Yes`, `apply`, `seed`.
9. **El respaldo es para el mismo clúster** (roles globales) y la huella **no** incluye contraseñas ni la configuración de roles; los volcados quedan en `db\backups` (no versionados; contienen datos de demostración).
10. **El e2e con navegador y el banner 503** dependen del backend/front: no se pudieron probar aquí; la BD y el runbook los habilitan.
11. **`56_mantenimiento.sh`** aparece como modificado después de `26_mantenimiento.sql` en el árbol: son los ajustes de la corrección de auditoría de E13, no de E14.

## 7. Mutaciones

**M468–M493 (25):** catálogo (tasa, tope de Libre inversión, regla de edad de Inmuebles, mínimo de CDT, recarga que no restaura); identidades (sin fijar, `verificar_correo` antes de fijar, `session_replication_role` sin restablecer); ADMIN como CLIENTE; hash que no corresponde; reloj final en manual; sin `sp_avanzar_todos` final; `bloqueado1` sin bloquear; mora distinta; Vehículo con descuento automático; sin `setseed`; **sin limpieza del esquema `seed`** (sin `trap`); el seed deja de negarse; **respaldo/restauración:** sin `--yes`, sin comparar el manifiesto, sin exigirlo, sin cerrar conexiones, sin comprobar que el volcado sea de este banco, manifiesto vacío, sin conservar `_previo`. **Resultado: 25 de 25 detectadas, sin equivalentes.** Las mutaciones rompen **copias** de `db/seed` (`SEED_DIR`) y corren sobre bases aisladas.

## 8. Verifícalo en pgAdmin

1. `db\ctl.cmd reset -Yes` → `db\ctl.cmd apply` → `db\ctl.cmd seed` (o `db\ctl.cmd restore inicial -Yes` si ya existe el respaldo).
2. Conexión **«Banco — administración (postgres)»** → base `banco` → Query Tool → *Open File* → [14-pgadmin-demo.sql](../evidencias/14-pgadmin-demo.sql) → **F5** (todo en `BEGIN … ROLLBACK`; resultados en *Messages*). Salida de referencia: [14-pgadmin-demo-salida.txt](../evidencias/14-pgadmin-demo-salida.txt).
3. Consultas sueltas: `SELECT username, rol, estado FROM usuario ORDER BY rol, username;` · `SELECT * FROM v_reloj_estado;` · `SELECT ok FROM v_integridad_global;` · `SELECT to_regnamespace('seed') IS NULL;` (el esquema `seed` ya no existe).
4. Flujo completo de demostración y apagón: [runbook-demo.md](../runbook-demo.md).

## 9. Limitaciones pendientes

* Decisiones del equipo: D11 (catálogo), D-E14-D2/D3, D1, D6, D7, D-E13-D1 siguen provisionales; D-E4-9 sigue pendiente de Juan.
* Coordinación con Jose para ejecutar `apply` + `seed` en el Compose final; e2e y banner 503 con el backend.
* Decisión tuya sobre los índices GIN de búsqueda (hallazgo 5).

## 10. Correcciones de la auditoría (2026-11-25)

### 10.1 Qué se cambió

| # | Defecto señalado | Corrección |
|---|---|---|
| 1 | Integridad del respaldo | `backup` **rechaza** una BD con `v_integridad_global.ok = false`; `restore` exige que el manifiesto declare integridad ok **y** que la BD restaurada tenga `ok = true` (ya no basta con que coincida con el manifiesto). Además `backup` rechaza una BD que **cambie mientras se respalda** (compara el manifiesto antes y después del volcado). |
| 2 | Huella pobre | La huella ahora es **una por tabla** (texto completo de **todas las columnas** de las 11 tablas de `public` y de `audit.evento`, ordenado) más la del **esquema** (funciones con dueño, permisos y `SECURITY DEFINER`; triggers con su estado). `restore` compara tabla por tabla y, si difiere, **nombra la tabla**. |
| 3 | Intercambio de bases | Secuencia nueva: `banco` → `banco_retirada`, paso → `banco` y, **solo al final**, `banco_retirada` → `banco_previo` (antes se borraba el `_previo` anterior al empezar). `recuperar` (idempotente) deshace un corte entre los dos renombrados o cierra un intercambio ya hecho; se ejecuta sola ante error o señal (HUP/INT/TERM) y al empezar cualquier `restore`; nuevo comando `ctl recuperar` para un corte duro. |
| 4 | Limpieza del seed | `sembrar.sh` atiende **HUP**, INT y TERM (antes solo EXIT/INT/TERM); ahora ejecuta `psql` en segundo plano con `wait` (la señal actúa de inmediato), cierra la sesión del seed (`application_name`) y reintenta el `DROP SCHEMA seed`. Nota: INT no es probable en un proceso en segundo plano no interactivo; se probaron HUP y TERM. |

Ganchos de **prueba** de `respaldo.sh` (variable `RESPALDO_FALLA`): `error_entre`, `term_entre`, `kill_entre`, `kill_despues`, `cambio_durante`. Tooling tocado además: `ctl.sh`/`ctl.ps1` (`recuperar`).

### 10.2 Pruebas (corridas individuales, bases aisladas)

| Archivo | Antes | Ahora | Qué se añadió |
|---|---|---|---|
| `reales/57_seed` | 54 | **56** | C11 (×2): señal **HUP** y **TERM** con el esquema `seed` ya creado → código 129/143, esquema eliminado, sesión cerrada, 0 usuarios, 0 patas, reloj real |
| `reales/58_respaldo` | 27 | **45** | E0–E4 (integridad: sabotaje real, backup y restore la rechazan, manifiesto falsificado con `integridad_ok=t`, cambio durante el backup); F1–F3 (**20 alteraciones** de datos, permisos y triggers: todas cambian la huella; control sin cambios = misma huella; manifiesto con 12 tablas + esquema); G0–G9 (fallo, TERM y **kill -9 entre los dos renombrados**: `banco` sigue recuperable, el `_previo` anterior intacto; `recuperar` idempotente; auto-recuperación del `restore`; kill después del segundo renombrado y cierre) ; C3 ahora nombra la tabla |

Totales de E14: 57 + 58 + 59 = **56 + 45 + 9 = 110** (antes 90). La suite completa **no se reejecutó** tras las correcciones (§10.4).

### 10.3 Mutaciones

* **Nuevas M494–M508 (15): 15 de 15 detectadas** (`14-seed-qa-correccion-mutaciones.txt`): backup sin integridad, restore sin integridad de paso, restore que acepta manifiesto `integridad_ok=f`, huella que solo cuenta filas, sin esquema, sin `audit.evento`, borrado anticipado del `_previo`, `recuperar` sin rollback o sin cierre, restore sin auto-recuperación o sin atender TERM, backup sin detectar cambios, `sembrar.sh` sin HUP, sin cerrar la sesión o sin `wait`.
* **Reejecución de las 40 de E14:** la última corrida completa dio **39 de 40**: **M489** («restore no exige manifiesto») quedó sin detectar porque otra validación (la del campo `integridad_ok`) también rechaza un respaldo sin manifiesto y la prueba C2 solo buscaba la palabra «manifiesto». Se afinó C2 para exigir el mensaje «falta el manifiesto» (58: 45/45 en verde) pero **la reejecución que lo confirmaría fue cancelada por indicación tuya**: M489 queda **sin confirmar con mutación**. Además se actualizaron los patrones de M484, M488, M490 y M493 por el cambio de estructura de los scripts (M484 y M488 verificados en la corrida de 39/40; M490 y M493 también detectadas en ella).

### 10.4 Pendiente (no ejecutado, a petición tuya)
* Reejecución de la tanda de mutaciones tras afinar C2 (confirmar M489).
* **Suite completa** (`ctl.sh test --evidence`): esperada 3252 − 90 + 110 = **3272**; **no verificada**.
* **Aplicación desde cero con `ctl.ps1`** con los scripts corregidos (`14-seed-qa-aplicacion.txt` es de la versión anterior, salvo `ctl.ps1 recuperar`, que solo se verificó por sintaxis).
* Estado del entorno: la última corrida de mutaciones se canceló a mitad; pueden quedar bases temporales (`banco_mut_base`, `banco_rs`, `banco_rs_base`, `banco_rs_otra`, `banco_rsx`); son desechables y las pruebas las eliminan al empezar. Los roles `banco_owner`/`banco_ledger` están sin login ni membresías. `banco` sigue limpia.
