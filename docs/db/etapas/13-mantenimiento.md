# Etapa 13 — Mantenimiento (`sp_avanzar_todos` y `sp_verificar_integridad`) · paquete de entrega

**Estado (2026-11-25): IMPLEMENTADA; auditoría con UN defecto del resumen corregido (§8); PENDIENTE DE TU APROBACIÓN FINAL.** Diseño v1.1 aprobado (`13-mantenimiento-diseno.md`; D-E13-1 a D-E13-6 con tus 2 ajustes) y seguido sin cambiar el alcance. **D-E13-D1 (¿ejecución periódica?) sigue siendo del equipo: hoy solo manual.** Sin commits; `front/` y backend intactos (el backend de `origin/main` es un borrador temporal y no se usó como autoridad; E13 no tiene endpoint). **E14 no iniciada.**

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| 2 procedimientos `sp_avanzar_todos(INOUT resultado jsonb)` y `sp_verificar_integridad(INOUT resultado jsonb)` + interna `_reglas_mantenimiento()` | `db/sql/26_mantenimiento.sql` (idempotente, transaccional, comentado; **no modifica ningún objeto de E1–E12**; sin tablas ni triggers nuevos) |
| Integración (solo inventarios) | `03_schema` (131 funciones), `10_libro_triggers` (§5-2), `09_idempotencia` (reaplica `26`) |
| Pruebas nuevas | `72_mantenimiento` (29) y `reales/56_mantenimiento` (33, tras §8) = **62** |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M434–M467** (34, tras §8) |
| Resumen para el backend | `13-resumen-para-juan.md` (no hay endpoint nuevo) |
| Evidencias | `docs/db/evidencias/13-mantenimiento*.txt`, `13-pgadmin-demo.sql` y su salida, `git_status_e13.txt` |

## 2. Cómo funciona

```
CALL sp_avanzar_todos();     (solo dueño/superusuario; SOLO, en autocommit)
 txn de captura : search_path → ids de TODAS las cuentas (orden de id) → COMMIT
 por cada cuenta, UNA transacción:
     search_path + lock_timeout (2 s) locales → UNA _reloj_instantanea() → _avanzar_hasta(cuenta, hoy, ahora)  (motor de E7–E9)
       · 55P03 (lock_not_available) → "omitida por timeout de bloqueo" (no se asume si fue la cuenta o el reloj)
       · cualquier otro error       → "con_error" (mensaje, hasta 20), SOLO esa cuenta se revierte
     COMMIT
 txn final      : search_path → resumen → 1 evento MANTENIMIENTO_AVANZAR (actor = session_user, sin la lista de errores) → COMMIT → NOTICE
CALL sp_verificar_integridad();   → UNA sentencia sobre v_integridad_*: {ok, conteos de v_integridad_global, detalle:{saldos, grupos, usuario, defensas, auth, creditos}} (≤ 20 filas defectuosas por control)
```

* **Resumen de `sp_avanzar_todos`:** `{cuentas, procesadas, con_cambios, grupos, omitidas_por_timeout_de_bloqueo, con_error, errores:[{cuenta_id, mensaje}], hoy_desde, hoy_hasta}`. Idempotente (la 2.ª corrida escribe 0 grupos). Todo el dinero sigue saliendo de `_asentar_grupo` (no toca el libro por su cuenta).
* **`search_path` en CADA transacción (ajuste 1):** cada `COMMIT` descarta lo fijado con `set_config(…, true)`; se fija en la captura, al empezar cada cuenta y en la transacción final. Se prueba estáticamente el orden de instrucciones (`S C F S R A C E S C`) y con 3 mutaciones (una por punto).
* **`55P03` (ajuste 2):** clave `omitidas_por_timeout_de_bloqueo`; se probó con una **cuenta** tomada por otra sesión y con el **reloj** tomado (misma señal, dos causas).
* **`sp_verificar_integridad`:** solo lectura, sin auditoría, no lanza error (se lee `resultado->>'ok'`); restaura el `search_path` del llamador.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`ctl.sh test --evidence 13-mantenimiento`, antes de §8) | **3158 aprobadas, 0 fallidas** (E12 cerró en 3100: **+58**, 0 menos; las adaptadas siguen verdes). El estimado del diseño era ≈ +60. |
| Pruebas nuevas | `72_mantenimiento` **29**, `reales/56_mantenimiento` **29** (33 tras §8: la suite tendría 3162; **no se repitió la suite completa**, solo las pruebas de E13, §8) |
| `reset` + 3 × `apply` desde cero | **sin errores** (`13-mantenimiento-aplicacion.txt`; **27 archivos** por pasada): 11 tablas + `audit.evento`, **131 funciones** (2 procedimientos), **21 triggers** (ninguno nuevo), **9 vistas**; `banco_app` ejecuta exactamente **40** (ninguno de E13); `v_integridad_global.ok`, 0 defensas fallidas; `banco` queda **limpia** (0 usuarios, reloj real, 0 eventos de mantenimiento, sin esquema `tests`) |
| Mutaciones nuevas M434–M462 (29) | **29 de 29 detectadas**, a la primera, 0 equivalentes (`13-mantenimiento-mutaciones.txt`) |
| Regresión (las 64 de E12: libro, auditoría, reloj, integridad, motor, `vista_cdts`, permisos, plantillas, admin, control) | **64 de 64** (`13-mantenimiento-mutaciones-regresion.txt`) |
| Demo de pgAdmin | `13-pgadmin-demo.sql` + salida real `13-pgadmin-demo-salida.txt` (parte 1 en `BEGIN … ROLLBACK`; parte 2, el cierre real, sobre una copia desechable que se eliminó) |

* **`72`** (una transacción con `ROLLBACK`; solo `sp_verificar_integridad` y el catálogo): informe = `v_integridad_global` (12 claves, mismos valores) y 6 detalles vacíos con el banco sano; **cada control detecta su sabotaje** con su fila (saldo de cuenta/bolsillo/CDT/crédito, pata suelta, grupo descuadrado, guardia caído, permiso de más, lista blanca rota, cliente sin cuenta, plan incoherente, envío sin recibo); tope de 20 filas con 30 defectos (conteo real 30); solo lectura y restauración del `search_path`; catálogo (`prokind='p'`, `SECURITY INVOKER`, sin `proconfig`, sin `EXECUTE` para nadie); orden estático de `set_config`/`COMMIT`/instantánea/motor; valores provisionales; `CALL` dentro de una transacción = `2D000` sin dejar rastro.
* **`reales/56`** (psql real, `CALL` en autocommit): resumen = lo escrito de verdad; **equivalencia con la ruta perezosa** (cliente puesto al día por `sp_avanzar_todos` = idéntico al de `vista_dashboard`, saldo/bolsillo/CDT/crédito/cuotas/multiconjunto de movimientos); idempotencia; 1 evento por corrida; **atomicidad** (falla inyectada en una cuenta: vecinas confirmadas, la fallida intacta; **corte de la conexión**: lo procesado queda confirmado, lo cortado intacto, sin evento, sin sesiones colgadas; re-ejecutar termina); **timeouts** de cuenta y de reloj; **concurrencia** (4 sesiones × 20 transferencias cruzadas durante el cierre: 80 de 80, sin deadlocks, libro cuadrado); `CALL` dentro de `BEGIN`/multisentencia falla; permisos efectivos 9/9; > 300 cuentas en < 30 s.

**Pruebas anteriores adaptadas (solo inventarios; ninguna se eliminó):** `03_schema` (131 funciones, +3 nombres), `10_libro_triggers` (el chequeo de «`search_path` fijo» ahora es solo para `prokind = 'f'`; 130 funciones de `banco_owner`), `09_idempotencia` (reaplica `26`).

## 4. Decisiones aprobadas y cómo se reflejan

| ID | Cómo quedó |
|---|---|
| D-E13-1 | 2 procedimientos + `_reglas_mantenimiento()` + `26_mantenimiento.sql`; sin tablas/triggers; `sp_cargar_demo` sigue en E14. |
| D-E13-2 | `SECURITY INVOKER` sin `SET`; `search_path` por `set_config` en cada transacción; una transacción y una instantánea **por cuenta**; bloque `EXCEPTION` por cuenta; `lock_timeout` 2 s; resumen `INOUT jsonb` + `NOTICE`; solo dueño/superusuario; error claro dentro de una transacción. |
| D-E13-3 | `sp_verificar_integridad`: una sentencia, conteos de `v_integridad_global` + ≤ 20 filas por control, sin error, sin permisos para roles de acceso. |
| D-E13-4 | 1 evento `MANTENIMIENTO_AVANZAR` por corrida; `sp_verificar_integridad` no audita. |
| D-E13-5 | Todas las cuentas (ids al empezar); el motor sale rápido sin trabajo. |
| D-E13-6 | Adaptaciones de `10`, `03` y `09_idempotencia`. |
| Ajuste 1 / 2 | Ver §2. |
| **D-E13-D1 (equipo)** | **Provisional: solo manual.** La BD no trae planificador; valores en `_reglas_mantenimiento()` (`lock_timeout` 2 s, 20 errores, 20 filas). |

## 5. Desviaciones y límites (sin ocultar nada)

1. **Excepción documentada a «todo `SECURITY DEFINER` con `search_path` fijo»:** PostgreSQL 16 no deja hacer `COMMIT` a un procedimiento con `SET` o `SECURITY DEFINER` (verificado y probado por M460/M461). Se compensa con `INVOKER`, sin permisos para nadie salvo dueño/superusuario, y `set_config` por transacción.
2. **Adaptación de `10`:** excluye `prokind = 'p'` del chequeo de `search_path` fijo; el conteo de funciones de `banco_owner` es **130** (el diseño decía 129; el dato real incluye la interna).
3. **Hallazgo corregido durante la implementación:** `sp_verificar_integridad` dentro de una transacción del llamador dejaba su `set_config` hasta el fin de esa transacción (rompía la resolución de los helpers de prueba); ahora **restaura el `search_path`** (prueba `72`/A3b, mutación M455).
4. **No se puede llamar dentro de una transacción** (`BEGIN … CALL`, scripts multisentencia, `DO` con `CALL` y 2D000): es una limitación de PostgreSQL, documentada en la demo. En un `DO`, además, `CALL sp_avanzar_todos()` sin variable de salida falla con otro error (`42601`); hay que pasar la variable.
5. **Aserciones:** +58 (≈ +60 del estimado); mutaciones **29** (≈ 20): se añadieron las de los dos ajustes (3 por `search_path`, 1 por `55P03`) y las de permisos/forma.
6. **Pruebas de tiempo** (`reales/56`: espera ≈ 2 s del `lock_timeout`; 300 cuentas < 30 s; transferencias concurrentes): cotas amplias; en un equipo muy cargado podrían ser sensibles. Las aserciones de `A4` usan un oráculo del libro (cuentas con patas nuevas) en vez de un número fijo.
7. **Arnés de mutaciones:** se añadió el interruptor `BASE_SQL` (vacío = no recorrer la base E2–E4 para las mutaciones de E13; las pruebas de E13 van primero) y el mensaje de `detectar` ahora prefiere `FAIL:`/`ERROR:` (antes podía mostrar una línea `PASS` que contenía la palabra ERROR; la detección se decide por el código de salida y no cambió).
8. **Límites de diseño:** cambia el estado **guardado** de muchas cuentas de golpe (hacer respaldo antes de una demostración, política P-DEMO de E3); una cuenta ocupada > 2 s se omite y se pone al día en su próxima operación; el `FOR SHARE` del reloj dura una transacción por cuenta, por lo que `hoy_desde` y `hoy_hasta` pueden diferir si el admin mueve el reloj durante la corrida; los eventos de auditoría no se borran (por eso la demo real va sobre una copia).

## 6. Mutaciones

**M434–M462 (29):** `COMMIT` por cuenta (M434), captura de errores (M435), `lock_timeout` (M436, M462), `55P03` como error (M437), instantánea única (M438), `search_path` en cada transacción (M439–M441), motor omitido (M442), conteos y errores del resumen (M443–M446), evento (nombre, errores, actor: M447–M449), captura incompleta (M450), informe (filas de créditos/defensas, tope, `ok`, restauración, muestra: M451–M456) y permisos/forma (M457–M461).

**Resultado: 29 de 29 detectadas, 0 equivalentes. Regresión: 64 de 64.**

## 7. Verifícalo en pgAdmin

1. Conexión **«Banco — administración (postgres)»** → base `banco` → Query Tool → *Open File* → [13-pgadmin-demo.sql](../evidencias/13-pgadmin-demo.sql). **Parte 1** (hasta el primer `ROLLBACK`): F5; los resultados salen en *Messages*. **Parte 2** (cierre real): ejecuta **cada sentencia por separado** (selecciónala y F5; `CALL sp_avanzar_todos()` no puede ir dentro de una transacción) y **sobre una copia**. Salida de referencia: [13-pgadmin-demo-salida.txt](../evidencias/13-pgadmin-demo-salida.txt).
2. Consultas sueltas (superusuario):
   * `CALL public.sp_verificar_integridad();` — informe `jsonb`; solo lectura.
   * `CALL public.sp_avanzar_todos();` — **solo**, en autocommit; devuelve el resumen y lo muestra como `NOTICE`.
   * `SELECT accion, actor_username, despues FROM audit.evento WHERE accion = 'MANTENIMIENTO_AVANZAR' ORDER BY orden DESC;`
   * `SELECT proname, prokind, prosecdef, proconfig FROM pg_proc WHERE proname LIKE 'sp\_%';` — `p`, `false`, `NULL`.
   * `SELECT public._reglas_mantenimiento();` — los valores provisionales.

## 8. Corrección de la auditoría: el resumen no debe contar lo revertido (2026-11-25)

**Lo señalado:** si una cuenta fallaba antes de asignar `v_g`, la variable conservaba el valor de la cuenta anterior y `con_cambios`/`grupos` podían contar movimientos revertidos. **Lo que encontré al revisarlo:** en el código entregado las actualizaciones de los contadores eran lo último **dentro** del bloque `BEGIN … EXCEPTION`, después de la llamada al motor; una cuenta que fallaba saltaba al manejador sin llegar a ellas, así que **el conteo erróneo no ocurría** con ese código (las pruebas no lo habrían detectado porque no lo comprobaban). Aun así la garantía dependía del **orden de las líneas**, no de la estructura, así que se volvió estructural, como se pidió.

**Corrección (`26_mantenimiento.sql`, solo el bucle de `sp_avanzar_todos`):**
* al empezar **cada cuenta** se reinician `v_g := 0` y `v_ok := false`;
* `v_ok := true` es **lo último** del bloque (solo si el reloj, el motor y todo el procesamiento de esa cuenta terminaron);
* **después** del bloque, `IF v_ok` actualiza `con_cambios`, `grupos` y el rango `hoy_desde`/`hoy_hasta`; una cuenta con error o con timeout de bloqueo no suma nada.

**Pruebas (`reales/56`, +4 aserciones: 29 → 33):**
* **C1b** (ampliación de C1: cuenta con trabajo **antes** de la fallida): `grupos` = exactamente los grupos **confirmados** en el libro en esa corrida (oráculo: `registrado_en` posterior a la marca), `con_cambios` = las cuentas con patas confirmadas (≥ 2: 1710 y 1712), y la fallida (1711) no dejó ni una pata ni cuenta.
* **D5/D6/D7** (timeout **después** de una cuenta con cambios: 1734 se procesa y 1735 está tomada por otra sesión): 1735 omitida (1), sin errores, 1734 al día y 1735 pendiente (D5); `grupos` y `con_cambios` coinciden con el libro, 1735 sin ninguna pata nueva (D6); la siguiente corrida la pone al día (D7).

**Mutaciones (M463–M467):** **M463** (sin reinicio **ni** bandera: la cuenta fallida arrastra el `v_g` de la anterior) **detectada por C1b**; **M464** (la omitida por timeout cuenta como con cambios) **detectada por D6**; **M465** (la cuenta con error cuenta como con cambios) **detectada por C1b**. **M466** (sin reinicio, queda la bandera) y **M467** (sin bandera, queda el reinicio) son **equivalentes declaradas**: cada defensa por sí sola basta, así que quitar una no es observable (la mutación que cuenta es quitar las dos, M463). Resultado: **3 detectadas + 2 equivalentes** (`13-mantenimiento-correccion-conteo-mutaciones.txt`); acumulado de E13: **32 detectadas + 2 equivalentes** de 34.

**Verificación (solo E13, sin repetir las regresiones de E1–E12 ni las 64 mutaciones):** `72` 29/29 (31 con aislamiento), `reales/56` 33/33 y `09_idempotencia` (reaplica `26`) en verde (`13-correccion-conteo-72/56/09.txt`; el filtro `56` también corre `56_motor_aleatorio`, de E7, sin cambios); `reset` + 3 × `apply` desde cero **sin errores**, 27 archivos, 131 funciones, 21 triggers, 9 vistas, `banco_app` en 40, `banco` limpia (`13-mantenimiento-aplicacion.txt` regenerado); demo de pgAdmin regenerada con el mismo resultado (12 y 0 grupos). El comentario `C5` de `72` (orden estático `S C F S R A C E S C`) no cambió.
