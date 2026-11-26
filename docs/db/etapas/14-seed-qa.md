# Etapa 14 — Seed y QA (catálogo, datos de demostración, respaldo/restauración, runbook y aceptación) · paquete de entrega

**Estado (2026-11-26): IMPLEMENTADA; además de las 4 correcciones de la 1.ª auditoría (§10) se aplicaron una 2.ª (§11: recuperación sin pérdida del `_previo` y backup con snapshot compartido) y una 3.ª revisión correctiva (§12: estado final estricto de `recuperar`, ganchos de prueba protegidos y candado entre procesos). Tras la 3.ª revisión se hizo la **regresión pedida (§13)**: suite completa 3313/0 y, tras añadir J11, **suite final 3314/0 (§13.5)**, mutaciones de `respaldo.sh` reejecutadas, `ctl.ps1` verificado y estado final comprobado. Verificación de la 2.ª revisión: pruebas específicas y mutaciones dirigidas (§11.4); la suite completa y la reejecución total de mutaciones NO se repitieron (§11.5). PENDIENTE DE TU AUDITORÍA FINAL. No se da por completada ni aprobada hasta tu aprobación explícita.** Diseño v1 aprobado (`14-seed-qa-diseno.md`; D-E14-1 a D-E14-7, D-E14-D1/D2/D3) con tus tres condiciones: protección del respaldo/restauración, limpieza del esquema temporal `seed` y reproducibilidad funcional de la demostración. **Sin commits.** `db/sql/` y todo objeto de E1–E13 **intactos** (131 funciones, `banco_app` = 40); `front/` y backend intactos (el backend de `origin/main` es un borrador temporal y no se usó como autoridad). E15 no existe; no se inició nada más.

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

### 10.4 Verificaciones finales (2026-11-26)

| # | Pendiente | Resultado | Evidencia |
|---|---|---|---|
| 1 | Reconfirmar **M489** («restore no exige manifiesto») | **DETECTADA** por `reales/58_respaldo` C2 («falta el manifiesto»): 1 de 1. Con ella, las 40 mutaciones de E14 quedan detectadas (39 en la corrida completa anterior + M489 reconfirmada con la prueba afinada) | `14-seed-qa-m489.txt` |
| 2 | Suite completa con los scripts corregidos | **3272 aprobadas, 0 fallidas** (la cifra esperada: 3252 − 90 + 110). `57_seed` 56, `58_respaldo` 45, `59_volumen` 9 dentro de la suite | `14-seed-qa-final.txt` |
| 3 | `reset` + 3 × `apply` con `ctl.ps1` actualizado | **Sin errores**: 27 archivos por pasada (81 en total), código de salida 0 en las 4 órdenes; 12 tablas (11 + `audit.evento`), **131 funciones** (2 procedimientos), **21 triggers**, **9 vistas**, `banco_app` ejecuta **40**, integridad ok, 0 defensas caídas, 0 usuarios, reloj real, catálogo vacío, sin esquemas `seed` ni `tests`; `ctl.ps1 recuperar` (nuevo) ejecutado sin nada que recuperar: código 0 e idempotente | `14-seed-qa-aplicacion-final.txt` |
| 4 | Las 5 bases temporales | Ver §10.5: **no estaban atascadas**; ya no existen | — |

Nota sobre la cifra de mutaciones: las corridas completas fueron M468–M493 25/25 (1.ª versión), M494–M508 15/15 y una reejecución de las 40 con 39/40 (M489 por una prueba débil, ya afinada y reconfirmada). **No** se hizo una última corrida única de las 40 sobre la versión final de los scripts; la evidencia es la suma de las anteriores más la reconfirmación de M489.

### 10.5 Por qué quedaron las 5 bases temporales (banco_mut_base, banco_rs, banco_rs_base, banco_rs_otra, banco_rsx)

* **No fue un fallo de PostgreSQL ni conexiones colgadas.** Al cancelar la última corrida de mutaciones solo se mató el proceso del anfitrión (`docker compose exec` / la redirección); todo indica que **el script de mutaciones siguió ejecutándose DENTRO del contenedor** (el contenedor no se reinició y las bases desaparecieron solas) y que las bases estaban en uso legítimo por esa corrida (`banco_rs*` por la prueba 58 y `banco_mut_base` por la plantilla del arnés).
* El intento de borrarlas que hice en ese momento fue **denegado por el sistema de permisos** de la sesión (no por la base de datos) y, además, habría competido con la corrida viva.
* **A las 23:09:15 (hora local) la propia corrida terminó** y sus limpiezas automáticas (`trap EXIT` del arnés y de las pruebas 57/58) eliminaron las bases y repararon los roles (el log del servidor muestra los avisos `role "banco_app" has not been granted` de `reparar_roles` a esa hora). Verificado después: solo existe `banco`; 0 sesiones; los roles `banco_owner` y `banco_ledger` sin login ni membresías; el contenedor no se reinició (inicio 19:51 del día anterior).
* **Lección:** cancelar una tarea desde el anfitrión **no detiene** el proceso del contenedor; para interrumpir una corrida hay que enviarle la señal dentro del contenedor, y las limpiezas por `trap` ya cubren el caso normal.
* Quedan **archivos temporales sueltos en `/tmp` del contenedor** (`seed_m`, `seed_mut`, `t58dbg.sh`, `mut_out`, `demo14.sql`, `comp.sql`, `c51_h.out`): no afectan a nada, se pierden al recrear el contenedor; no se borraron por no estar en el alcance.

## 11. 2.ª revisión correctiva (2026-11-26): recuperación y consistencia del backup

Solo cambian `db/seed/respaldo.sh`, `db/tests/reales/58_respaldo.sh` y `db/tests/mutaciones/mutaciones.sh` (más este informe y el runbook). **No se tocó `db/sql/`, `front/`, el backend ni las decisiones funcionales del seed** (`20_demo.sql`, `10_funciones_seed.sql`, `00_catalogo.sql` y `sembrar.sh` quedan idénticos).

### 11.1 Hallazgo 1 — Recuperación (`recuperar()` y cierre del intercambio)

**Defectos encontrados en la versión anterior:** (a) `recuperar()` devolvía éxito siempre (ignoraba los errores de los renombrados); (b) al cerrar un intercambio **eliminaba `banco_previo` antes** de comprobar que `banco_retirada` se renombraba bien: un fallo en ese renombrado dejaba **sin el respaldo anterior** (en `restore`, además, el `DROP` del `_previo` ocurría antes del renombrado final).

**Corrección:**
* Cada cambio de nombre pasa por `renombrar TRANSICION ORIGEN DESTINO` (cierra conexiones, hasta 5 reintentos, devuelve 0/1) con gancho de fallo por transición.
* **`cerrar`** (compartido por `restore` y `recuperar`): 1) **aparta** el `_previo` anterior como `banco_previo_antiguo` (no lo elimina); 2) renombra la retirada a `_previo`; 3) **solo entonces** elimina el apartado. Si el paso 2 falla, **el previo anterior vuelve a su nombre**; si tampoco puede, se detiene con `ERROR: RECUPERACION INCOMPLETA` indicando que el previo sigue **intacto** como `banco_previo_antiguo`. Retoma un cierre interrumpido en cualquier punto (incluido un corte duro justo tras apartar).
* **`recuperar`** distingue los estados (retirada sin banco → la devuelve a su nombre; banco y retirada → cierra; resto de apartado → lo elimina o lo devuelve a `_previo`), **devuelve código 1 y mensaje explícito si no logra el estado consistente** y en ese caso no elimina nada. `restore` se niega a continuar si no puede recuperar al empezar, y sus *trap* (EXIT/HUP/INT/TERM) terminan con ERROR explícito y código distinto de 0 si la recuperación quedó incompleta.
* `banco_previo_antiguo` se añade a los nombres que `respaldo.sh` no acepta como base.

### 11.2 Hallazgo 2 — Consistencia del backup

**Defecto:** el manifiesto se calculaba en varias consultas separadas **antes** de `pg_dump` y se recalculaba **después**; iguales antes/después no prueban que el volcado sea ese contenido (un cambio y su reversión alrededor del volcado pasaba inadvertido, y ni siquiera el manifiesto era un solo estado).

**Corrección (`cmd_backup`):** **un único snapshot**. Una sola sesión `psql` abre una transacción `REPEATABLE READ READ ONLY`, **exporta su snapshot** (`pg_export_snapshot`), calcula en ella la integridad, las huellas por tabla y del esquema (una sola sentencia) y, **sin cerrar la transacción**, ejecuta `pg_dump --snapshot=<id>` (`\!` de psql). Manifiesto y volcado describen **exactamente el mismo estado**, ocurra lo que ocurra en la BD mientras tanto; ya no se comparan dos huellas. La integridad se evalúa en ese mismo snapshot (y se conserva el chequeo previo que falla rápido). Se corrigió además que las lecturas de la huella usaran los ajustes de sesión (`ALTER DATABASE … SET timezone` pesaba más que `PGOPTIONS`): ahora se fijan `TimeZone`, `DateStyle` e `IntervalStyle` de forma explícita, idénticos dentro y fuera del snapshot (el manifiesto declara `consistencia=snapshot`).

### 11.3 Pruebas nuevas (`reales/58_respaldo`: 45 → **64**, +19; se quitó E4 «rechaza una BD que cambia», obsoleta)

| Bloque | Qué prueba |
|---|---|
| **H0–H15** (fallo en cada transición) | `retirar`: error y nada cambia · `poner`: se recupera sola (banco = anterior, previo intacto) · `poner` **y** `recuperar_retirada`: ERROR EXPLÍCITO «RECUPERACION INCOMPLETA», banco ausente pero la BD anterior **intacta** como retirada · `recuperar` **no** devuelve éxito si no puede (código ≠ 0) y luego sí devuelve la BD · `apartar` falla: el **previo anterior NO se elimina**, error explícito, `recuperar` cierra · `cerrar` falla: el previo apartado **vuelve a su nombre** · `cerrar` y `deshacer_apartar` fallan: nada eliminado (previo intacto como `_previo_antiguo`, anterior como retirada), `recuperar` termina y elimina el apartado **solo después** · **kill -9** justo tras apartar: estado recuperable y `recuperar` (idempotente) lo cierra · resto de `_previo_antiguo` · estado sano. Cada caso comprueba la **huella** de banco, previo, retirada y apartado. |
| **I1–I4** (consistencia, concurrente) | I1: cambio **permanente** (+ una transferencia) **después del snapshot y antes de `pg_dump`** (gancho `pausa_dump`, 4 s): código 0, el **volcado restaurado en una BD aparte coincide tabla por tabla con el manifiesto** y el manifiesto es el estado anterior al cambio (la BD viva ya es otra) · I3: cambio y **reversión (A-B-A)** durante la ventana · I4: un **modificador continuo** (120 pares +1/−1) durante **3 respaldos seguidos**: los 3 correctos y coincidentes. |

### 11.4 Resultados

| Verificación | Resultado | Evidencia |
|---|---|---|
| `reales/58_respaldo` (corrida directa) | **64 aprobadas, 0 fallidas** | — |
| Por el *runner* estándar (`ctl.sh test 58`, incluye `58_creditos` de E8) | **138 aprobadas, 0 fallidas** (`58_respaldo` = 64) | `14-seed-qa-2a-correccion-58.txt` |
| Mutaciones dirigidas (nuevas + con patrón actualizado): M490, M492–M494, M498, M502, M505, M509–M512 | **11 de 11 detectadas** (la corrida de 12 incluyó M513 mal etiquetada, ver abajo) | `14-seed-qa-2a-correccion-mutaciones.txt` |
| **M513** (chequeo previo de integridad del backup) | **EQUIVALENTE declarada**: el chequeo dentro del snapshot rechaza igual; la 1.ª corrida la mostró «detectada» por un error del arnés (`equivalente` usaba la BD de mutaciones SQL), corregido con `equivalente_seed` y reejecutada sola | `14-seed-qa-m513.txt` |
| Mutaciones nuevas: M509 (recuperar devuelve éxito aunque falle), **M510 (cerrar elimina el previo antes de apartarlo: el defecto)**, M511 (sin deshacer el apartado), M512 (no elimina el apartado), **M505 (backup sin `--snapshot`)** | detectadas | ídem |
| Camino canónico de Windows (`ctl.ps1`): `backup`, `restore` sin/con `-Yes`, `descartar-previo`, `recuperar` | todo correcto en `banco` (vacía); `restore` de un respaldo **viejo** (manifiesto del formato anterior) se **rechaza** por no coincidir y `banco` no cambia | `14-seed-qa-2a-correccion-ctl.txt` |

Patrones reescritos en esta revisión (por el cambio de estructura de `respaldo.sh`): M490, M492, M493, M494 (ahora rompe los dos chequeos de integridad), M498, M502 y M505.

### 11.5 Lo que NO se ejecutó y limitaciones (sin ocultar nada)

* **No se reejecutó la suite completa** (si se ejecuta, la cifra esperada es 3272 − 45 + 64 = **3291**) **ni la tanda completa de mutaciones de E14**: M487–M489, M491, M495–M497, M499–M501, M503–M504 y M506–M508 **no se reejecutaron** tras reescribir `respaldo.sh` (sus patrones se verificaron como existentes por el propio arnés solo en las 12 que sí corrieron; las demás quedan por reconfirmar si lo pides). `reales/57_seed` no se reejecutó (no depende de `respaldo.sh`).
* **Respaldos hechos con la versión anterior** (manifiesto sin snapshot, huellas calculadas con otra zona horaria de sesión) **ya no pasan la verificación de `restore`**: se rechazan con «NO coincide con el manifiesto» y `banco` no cambia (comprobado). Hay que **volver a generarlos** (`db/backups/banco_inicial.dump` es uno de ellos).
* **DDL concurrente:** el snapshot cubre los datos y el catálogo vistos por `pg_dump`; una operación DDL concurrente (solo la haría un superusuario) espera a los bloqueos de `pg_dump` pero no se probó.
* La transacción de snapshot dura lo que dure `pg_dump` (a esta escala, segundos): con bases muy grandes retrasaría la limpieza de versiones muertas.
* `recuperar` no puede actuar si PostgreSQL no responde o si hay conexiones que se reabren sin parar (reintenta 5 veces por renombrado): en ese caso devuelve ERROR y deja las bases intactas.
* Los ganchos de prueba `RESPALDO_FALLA` y `RESPALDO_FALLA_RENAME` existen en el script de producción: solo actúan si esas variables de entorno están definidas.
* Las bases temporales de las pruebas se eliminan por `trap`; no quedan restos tras las corridas (`banco` limpia, sin `banco_previo`).

## 12. 3.ª revisión correctiva (2026-11-26): estado final de `recuperar`, ganchos protegidos y serialización

Solo cambian `db/seed/respaldo.sh`, `db/tests/reales/58_respaldo.sh` y `db/tests/mutaciones/mutaciones.sh` (más este informe y el runbook). **No se tocó `db/sql/`, `front/`, el backend ni las decisiones funcionales del seed.** Se **mantienen** el snapshot compartido del backup y la recuperación sin pérdida del `_previo` (§11): sus pruebas H0–H15 e I1–I4 siguen en verde.

### 12.1 Punto 1 — Estado final de `recuperar()`
* **Defecto:** `recuperar` devolvía éxito cuando no existía la BD principal (si no había nada que arreglar) y no distinguía estados ambiguos.
* **Corrección:** se separan dos funciones. **`sanear`** (usada al empezar un `restore`) termina o deshace el intercambio pero **no exige** que la base exista (una primera restauración parte de una base inexistente). **`recuperar_estricto`** (comando `recuperar` y los *trap* de `restore` sobre una base que existía) añade la **verificación explícita del estado final**: la BD principal **debe existir** y no pueden quedar `_retirada`, `_previo_antiguo` ni `_restaurando`; si no, `ERROR: RECUPERACION INCOMPLETA` y código 1.
* **Estados ambiguos (se detiene sin tocar nada):** sin banco con retirada **y** apartado a la vez; banco, retirada, previo y apartado a la vez. Resto de estados: ver el comentario de `sanear`.

### 12.2 Punto 2 — Ganchos de prueba protegidos
`RESPALDO_FALLA` y `RESPALDO_FALLA_RENAME` solo actúan con **`RESPALDO_ENTORNO_PRUEBAS=1`** y **nunca sobre la BD real `banco`**. Sin el indicador se **descartan al arrancar** (`unset`) con un aviso por stderr; además cada gancho (`hook`, `falla_rename`) comprueba el indicador y la base. Las pruebas los habilitan expresamente (`RF`/`RX`) y se añadieron pruebas de que **sin** el indicador no tienen efecto (K1–K4). Se añadieron ganchos de pausa (`pausa_restore`, `pausa_entre`) para las pruebas de concurrencia; la espera es cortable por señal.

### 12.3 Punto 3 — Serialización entre procesos (candado)
* `backup`, `restore`, `recuperar` y `descartar` sobre **la misma base** toman un **candado consultivo de PostgreSQL** (`pg_try_advisory_lock(7314, hashtext('respaldo:<base>'))`) sostenido por una **sesión independiente**: vale entre procesos y conexiones distintas. Si está ocupado esperan `RESPALDO_ESPERA` s (60 por omisión; 0 = rechazar de inmediato) y terminan con **ERROR «ocupado» (código 75)**; operaciones sobre **otras bases** no se bloquean. Una segunda restauración **no puede tocar la BD de paso ni la recuperación de la primera**: ni siquiera llega a `sanear`.
* Se libera siempre (éxito, error, HUP/INT/TERM) y también tras un **`kill -9`**: un vigilante cierra la sesión **desde el servidor**.
* **Hallazgo importante (causa raíz de reinicios del servidor durante el desarrollo de esta revisión):** en el contenedor `db` **el PID 1 es el postmaster**, que **adopta a todo proceso huérfano**; si un hijo adoptado **muere por una señal o sale con un código distinto de 0** (psql sale con 2 al perder la conexión), el postmaster lo toma por un proceso de servidor caído y **reinicia toda la instancia** (log: «server process (PID n) was terminated by signal 15 / exited with exit code 2 … reinitializing»). El diseño final evita ambas cosas: el titular y el vigilante son *subshells* que **siempre salen con 0**, el candado se cierra con `pg_terminate_backend` (nunca con señales a psql) y `liberar` **espera** (`wait`) a sus hijos antes de salir. En la corrida final de `58_respaldo` **no hubo ningún reinicio del servidor**. Las pruebas que envían señales lo hacen solo a un PID verificado como `respaldo.sh` (`matar`), por haberse producido una señal a un PID reutilizado en una ejecución simultánea mía (ver 12.5).

### 12.4 Pruebas nuevas (`reales/58_respaldo`: 64 → **86**, +22)

| Bloque | Qué prueba |
|---|---|
| **J1–J10** (estados incompletos y ambiguos) | `recuperar` sin banco → error; solo previo → error sin tocar nada; **ambiguos** (R+O sin banco; B+R+V+O) → error «AMBIGUO» y **nada renombrado ni eliminado**; BD de paso suelta → se elimina; apartado sin previo → vuelve a `_previo`; retirada sin previo → se cierra; solo retirada → vuelve a banco (y se exige que exista); **primera restauración sobre base inexistente** funciona, y una primera restauración fallida no da falsos «RECUPERACION INCOMPLETA» |
| **K1–K4** (ganchos) | sin el indicador: `kill_entre` (kill -9), `error_entre` + renombrados que «fallan» y `pausa_dump` **no tienen efecto**; con el indicador pero sobre la BD real `banco` también se rechazan |
| **L1–L8** (concurrencia real, procesos independientes) | con una restauración A en curso (candado tomado, BD de paso creada): una **segunda restauración se rechaza (75)** sin tocar la BD de paso de A; también un backup, un `recuperar` y un `descartar`; el candado es **por base** (un backup de otra base no espera); A termina bien; el candado se **libera** al terminar; **serialización** (B espera a A, ambas terminan y el resultado es consistente); **interrupción de A con TERM** entre los renombrados mientras B espera: A se recupera sola (143), B no ve la BD intermedia y restaura después; **corte duro (kill -9) de A** mientras B espera: el candado se libera solo, B recupera primero la BD intermedia y luego restaura |

### 12.5 Resultados

| Verificación | Resultado | Evidencia |
|---|---|---|
| `reales/58_respaldo` (corrida directa, sola) | **86 aprobadas, 0 fallidas**; 0 reinicios del servidor durante la corrida | `14-seed-qa-3a-correccion-58.txt` |
| Mutaciones dirigidas de esta revisión | **8 de 8 detectadas** (M502, M514–M520: recuperar sin BD principal, estados ambiguos, ganchos sin indicador y sobre `banco`, sin candado, candado global, sin vigilante tras kill -9) | `14-seed-qa-3a-correccion-mutaciones.txt` |

**Incidente de esta revisión (para tu información):** al relanzar la prueba mientras otra ejecución mía seguía viva dentro del contenedor (cancelar la tarea desde el anfitrión no detiene el proceso del contenedor, lección ya anotada), ambas compartieron bases y una señal llegó a un PID reutilizado, reiniciando PostgreSQL varias veces. No dejó datos corruptos (`banco` limpia, solo existen `banco` y `banco_test`), pero obligó a (a) guardar el `kill` de las pruebas con `matar` y (b) descubrir la causa raíz de los huérfanos (12.3).

### 12.6 No ejecutado y limitaciones
* **No se repitió la suite completa** (si se ejecuta, esperada: 3291 − 64 + 86 = **3313**) **ni todas las mutaciones** de E14; solo las dirigidas de esta revisión (y M502, cuyo patrón cambió). Las demás mutaciones de §10 y §11 **no se reejecutaron** tras reescribir `respaldo.sh`.
* La serialización depende de que **todo acceso pase por `respaldo.sh`** (el comando `ctl`): un `pg_dump`/`pg_restore` o un `ALTER DATABASE` manual no toma el candado.
* El candado es de **sesión** y vive en el servidor: si PostgreSQL se reinicia durante una operación, el candado se pierde (la operación fallará por la caída; `recuperar` sanea).
* Quedan procesos `sleep` de las pausas de prueba (hasta 8 s) tras una señal: inofensivos (salen con 0).
* Los ganchos siguen existiendo en el script de producción pero solo con el indicador explícito y fuera de `banco`.
* **Mutaciones lentas:** cada una ejecuta `58_respaldo` (≈ 7 min) con modo de falla rápida; una corrida completa de las 25+ mutaciones de respaldo tardaría varias horas.

## 13. Verificación de regresión tras la 3.ª revisión (2026-11-26)

Alcance: solo las verificaciones pedidas. **`respaldo.sh` no se modificó en esta ronda.** Cambios: `db/tests/reales/58_respaldo.sh` (nueva prueba **J11**) y `db/tests/mutaciones/mutaciones.sh` (patrón de **M500** corregido). No se tocó `db/sql/`, `front/`, el backend ni las decisiones del seed. Sin commits ni push.

### 13.1 Qué se ejecutó, qué quedó pendiente y qué es equivalente

| Verificación | Estado | Resultado | Evidencia |
|---|---|---|---|
| Suite completa (`ctl.ps1 test`) | **Ejecutada** | **3313 aprobadas, 0 fallidas** (cifra real, coincide con la esperada); 1.017,8 s | `14-seed-qa-regresion-suite.txt` |
| `reales/58_respaldo` tras añadir J11 (corrida directa) | **Ejecutada** | **87 aprobadas, 0 fallidas**; 0 reinicios del servidor | `14-seed-qa-regresion-58.txt` |
| Mutaciones de `respaldo.sh` M487–M501, M503–M505, M509–M513 (23) | **Ejecutadas** sobre la versión actual | **21 de 23 detectadas** a la primera, 2 sin detectar (ver 13.2); M513 declarada equivalente | `14-seed-qa-regresion-mutaciones.txt` |
| M500 y M509 tras corregirlas | **Ejecutadas** | **2 de 2 detectadas** (M500 por G1; M509 por J11) | `14-seed-qa-regresion-mutaciones.txt` |
| M502 y M514–M520 | Ejecutadas en la 3.ª revisión (§12) sobre la versión actual | 8 de 8 detectadas | `14-seed-qa-3a-correccion-mutaciones.txt` |
| `ctl.ps1` backup / restore / recuperar / descartar-previo y `-Yes` | **Ejecutada** | Todo según lo esperado (13.3) | `14-seed-qa-regresion-ctl.txt` |
| Estado final de `banco`, bases temporales y respaldos | **Comprobado** | Ver 13.4 | `14-seed-qa-regresion-ctl.txt` (§8–9) |
| **Equivalente** | M513 | El chequeo previo de integridad del backup es una defensa redundante: el del snapshot rechaza igual una BD dañada con el mismo mensaje. No es un hueco de pruebas | — |
| **No ejecutado (fuera de alcance)** | M468–M485 (seed), M506–M508 (`sembrar.sh`) y la regresión E1–E13 completa | No dependen de `respaldo.sh`; no se repiten | — |
| Suite completa **después** de añadir J11 | **Ejecutada** (13.5) | **3314 aprobadas, 0 fallidas**; 920,3 s. La de la primera fila (3313) se corrió **antes** de J11 y queda como antecedente | `14-seed-qa-regresion-suite-final.txt` |

### 13.2 Fallos encontrados y corregidos
* **M500 (no detectada) — defecto de la mutación, no del producto.** Usaba una variable `$V` que no existe en `cmd_restore`, de modo que el `DROP DATABASE` no hacía nada (la mutación era un *no-op*). Se corrigió para eliminar `${B}_previo` y ahora la detecta **G1** (el _previo anterior sigue intacto tras un fallo entre renombrados).
* **M509 (no detectada) — hueco real de pruebas.** `recuperar_estricto` ya cubre el comando `recuperar` (verifica el estado final), pero ninguna prueba comprobaba que **`restore` se niega a continuar cuando no puede sanear un intercambio previo** (falla el renombrado de la retirada a `banco`). Se añadió **J11** a `58_respaldo` (87 pruebas); ahora M509 se detecta. Sin cambios en `respaldo.sh`.

### 13.3 `ctl.ps1`
| Comando | Comprobación | Resultado |
|---|---|---|
| `backup regresion` | crea `dbackupsanco_regresion.dump` + `.huella` (consistencia=snapshot, integridad_ok=t) | código 0 |
| `backup ../x` | nombre inválido rechazado | código 1 |
| `restore regresion` **sin `-Yes`** | se niega y **no modifica nada** (solo existen `banco` y `banco_test`) | código 1 |
| `restore noexiste -Yes` | error «No existe …» | código 1 |
| `restore regresion -Yes` | restaura; la anterior queda como `banco_previo`; huella de `banco` = huella del manifiesto (`cea604ad…`); `v_integridad_global.ok = t` | código 0 |
| `recuperar` (estado sano, y de nuevo tras descartar) | éxito idempotente, sin tocar nada | código 0 |
| `descartar-previo` (y de nuevo sin previo) | elimina `banco_previo`; idempotente | código 0 |

Nota: `banco` estaba vacío (sin seed: 0 usuarios, 0 patas), de modo que la verificación valida los mecanismos, no los datos de demo. `reset -Yes` **no se ejecutó** (destructivo y ajeno a esta ronda).

### 13.4 Estado final
* **Bases:** solo `banco` y `banco_test`; no quedan bases temporales (`banco_rs*`, `banco_qq*`, `banco_mut`, `banco_previo`). **Ningún candado de respaldo retenido** y ningún proceso `respaldo.sh` vivo.
* **Respaldos en la carpeta db/backups:** `banco_inicial` y `banco_consistente` (preexistentes, ignorados por Git); el de esta verificación (`banco_regresion`) se eliminó al terminar.
* **Contenedor `/tmp`:** se eliminaron los restos de mis pruebas (volcados `dbg`/`q`, la copia `seed_mut` del arnés y **247 archivos `respaldo_lock.*`**). Esos archivos los dejan **solo** los procesos matados con `kill -9` (no pueden limpiar su propio rastro); se comprobó que las operaciones normales (`recuperar`, `descartar-previo`, `backup`) **no dejan ninguno** (0 antes, 0 después). Son archivos sueltos de `/tmp` (sin efecto sobre el candado, que vive en el servidor); queda anotado como limitación menor.
* `git status`: solo los cinco archivos modificados esperados (`respaldo.sh`, `58_respaldo.sh`, `mutaciones.sh`, este informe y el runbook) y evidencias nuevas en `docs/db/evidencias/`; `db/sql/`, `front/` y el backend sin cambios.

### 13.5 Suite completa final (con J11 y los scripts actuales)

Única verificación de esta ronda: `dbctl.ps1 test -Evidence 14-seed-qa-regresion-suite-final`, sobre el estado actual del árbol de trabajo (sin cambios de código respecto de 13.1; solo se actualizó este informe). **No se repitieron mutaciones ni otras verificaciones.**

| Verificación | Resultado | Evidencia |
|---|---|---|
| Suite completa, código de salida | **3314 aprobadas, 0 fallidas**; código 0; 920,3 s | `14-seed-qa-regresion-suite-final.txt` |
| Coincidencia con lo esperado | 3313 (antes) + J11 = **3314**; coincide con el cálculo, y es la cifra real contada (3314 líneas «ok») | idem |
| J11 presente y aprobada | «ok J11 un restore que NO puede sanear un intercambio previo … se NIEGA a continuar» | idem |
| Sin regresiones | 0 fallidas en E1–E14; sin cambios en `db/sql/` | idem |

**Observación (no es un fallo, pero la dejo registrada):** el registro de PostgreSQL muestra **2 reinicios de la instancia durante la suite** (05:18:20 y 05:18:25), ambos con la misma causa: la prueba de interrupción de `reales/57_seed` (HUP y TERM sobre `sembrar.sh`, con un `SELECT pg_sleep(120)` inyectado) deja un `psql` huérfano; al cerrarse su sesión desde el servidor sale con código 2 y el postmaster (PID 1 del contenedor, que adopta huérfanos) reinicia la instancia, según el mecanismo ya descrito en 12.3. Es una propiedad de esa prueba **ya existente** (`57_seed.sh` no se modificó en esta ronda ni en la 3.ª revisión), la prueba la espera y pasa; `58_respaldo` **no** provocó ningún reinicio. No verifiqué el registro del servidor de la corrida anterior (3313), así que no puedo afirmar si allí también ocurrió. **No se modificó la prueba 57** por estar fuera del alcance pedido.

**Estado tras la suite:** solo existen `banco`, `banco_test` y `postgres` (sin bases temporales); 0 candados de respaldo retenidos; 0 procesos `respaldo.sh`; respaldos en `db/backups` = `banco_inicial` y `banco_consistente`. Quedaron 15 archivos sueltos `respaldo_lock.*` en el `/tmp` del contenedor (los dejan las pruebas con `kill -9`, limitación menor ya descrita en 13.4): se eliminaron.

**E14 continúa pendiente de tu auditoría final; no se marca como aprobada.**
