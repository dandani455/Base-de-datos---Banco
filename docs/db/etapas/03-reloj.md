# Etapa 3 — Reloj bancario · paquete de entrega

**Estado:** ✅ **APROBADA oficialmente por el responsable de BD (2026-11-22)** tras la corrección de la sección 13. **Aclaración funcional posterior (2026-11-23): política de demostraciones, documentada en la sección 14 como una capa de USO separada de la mecánica del reloj; no cambia ningún script, prueba ni garantía técnica de E3.** **D4 = opción A (definitiva)** según tu aprobación: el reloj manual **solo adelanta**; **volver a fecha real está siempre permitido** y deja `fecha_sistema = NULL`; **no existe `desfase_dias`** ni ningún reloj continuo con desfase. **Sin commits** (todo sigue sin versionar en `feat/db-core`). No se tocó `front/`, backend, `docs/specs`, `docs/superpowers` ni archivos de otros integrantes. No se tomó ninguna decisión financiera pendiente (D1, D6, D7, D8, D10–D13): no hay intereses, cuotas, mora ni abonos; solo las **reglas puras de tiempo** que E7–E9 necesitarán. (E4 se diseña en documentos aparte.)

Diseño aprobado: [03-reloj-diseno.md](03-reloj-diseno.md) (con la opción C **descartada**; ver sección 7 "Desviaciones") · E2: [02-libro-mayor.md](02-libro-mayor.md).

## 1. Qué se entrega

| # | Entregable | Dónde |
|---|---|---|
| 1 | **Scripts SQL** (3 nuevos + 4 ajustados) | `db/sql/10_reloj_estructura.sql`, `11_reloj_funciones.sql`, `12_reloj_triggers.sql`; ajustados `03_schema.sql` (comentarios del reloj), `05_permisos.sql` (re-concede `v_reloj_*`), `07_libro_mayor_funciones.sql` (regla de fecha del libro, reloj protegido en los event triggers), `09_integridad.sql` (+4 triggers y +2 controles de defensas) |
| 2 | **Pruebas automatizadas** | SQL: `db/tests/30…35_reloj_*.test.sql`; conexiones reales y concurrencia: `db/tests/reales/36_reloj_conexiones.sh`, `37_reloj_concurrencia.sh`, `38_reloj_instantanea.sh`; mutaciones: `db/tests/mutaciones/mutaciones.sh` (M25–M50); las de E1/E2 adaptadas (sección 8) |
| 3 | **Evidencias** | `docs/db/evidencias/03-reloj.txt` (suite completa), `03-reloj-mutaciones.txt`, `03-reloj-correccion-instantanea.txt` (regresión tras la corrección de la sección 13), `03-reloj-aplicacion.txt` (reset + 3 × `apply`), `03-pgadmin-demo.sql` y su salida real `03-pgadmin-demo-salida.txt`, `git_status_e3.txt` |
| 4 | **Documentación** | este archivo, el encabezado del diseño, `docs/db/00-entorno.md`, `COMMENT ON` en cada función, trigger, vista y restricción nueva |
| 5 | **Guía de verificación en pgAdmin** | sección 9 + `docs/db/evidencias/03-pgadmin-demo.sql` |

## 2. Resultado de un vistazo

| Verificación | Resultado |
|---|---|
| Suite completa (`db\ctl.cmd test`) | **1197 aprobadas, 0 fallidas** (E1 y E2 adaptadas: 836 · E3 SQL: 241 · E3 conexiones reales y concurrencia: 120) |
| Ejecución desde cero | `reset` + 3 × `apply`: **0 errores** (13 archivos; catálogo: 11 tablas en `public` + `audit.evento`, 29 funciones, 16 triggers, 2 event triggers, 6 vistas) |
| Mutaciones | **50 de 50 detectadas** (24 de E2 + 23 del reloj + 3 de la corrección de la instantánea) |
| Integridad | `v_integridad_global.ok = true` y `v_integridad_defensas` sin controles fallidos (ahora 30 controles) al terminar todas las pruebas |
| Concurrencia | 0 deadlocks y 0 timeouts; una operación en vuelo ve **una sola fecha** aunque el admin cambie el reloj; 120 operaciones simultáneas con 120 cambios de reloj aleatorios: todas aceptadas |
| Tiempo inyectado | 4000 pasos aleatorios contra un modelo independiente: 0 discrepancias |
| Tablas | `public` sigue con **exactamente 11 tablas**; `audit.evento` en `audit` |

## 3. Cómo funciona (opción A)

```
hoy_banco()   = modo real:   (_ahora_real() AT TIME ZONE 'America/Bogota')::date   -- _ahora_real() = clock_timestamp() (reloj de PARED, no now());
                                                                                   -- zona por código, no la de la sesión
                modo manual: reloj.fecha_sistema
ahora_banco() = hoy_banco() + la HORA REAL de Bogotá                               -- en manual NO es monotónico (ver 6.5)

PUT /admin/reloj  ->  _reloj_actualizar(usar boolean, fecha text)                  (E11 lo envolverá con _validar_admin)
   usar = true   : modo real. SIEMPRE permitido (aunque la fecha real sea anterior a la simulada). fecha_sistema := NULL
   usar = false  : modo manual con fecha 'YYYY-MM-DD'. Solo igual o posterior al hoy_banco() actual.
                   Retroceso  -> 'El reloj no puede retroceder'   (P0001, mensaje del contrato)
                   Texto mal formado / fuera de 2000-01-01..2100-12-31 -> 'Fecha inválida'   (P0001, PROVISIONAL, ver D-E3-6)
GET /admin/reloj  ->  _reloj_vista() = { usar_fecha_real, fecha_sistema: null | 'YYYY-MM-DD', fecha_actual = hoy_banco() }

Cada operación de negocio (E4+):  SELECT hoy, ahora FROM _reloj_instantanea();       -- FOR SHARE hasta el COMMIT
   usa ESE (hoy, ahora) durante toda su ejecución; el UPDATE del admin espera a las operaciones en vuelo.
Libro mayor (E2 modificado, D-E3-3): una pata no puede tener (fecha AT TIME ZONE 'America/Bogota')::date > hoy_banco().
```

**Máquina de estados** (la implementa `trg_reloj_a_validar`; rige también para el superusuario por *datos*). `H` = hoy del banco antes del cambio; "banco vacío" = ninguna fila en `transaccion`.

| De → a | Resultado |
|---|---|
| real → real (con o sin fecha basura) | permitido, idempotente, `fecha_sistema` queda `NULL` |
| real → manual(F) | `F ≥ H` permitido; `F < H` → `El reloj no puede retroceder` |
| manual(F) → manual(F2) | `F2 ≥ F` permitido (incluye `F2 = F`); `F2 < F` → `El reloj no puede retroceder` |
| manual(F) → real | **siempre** permitido; `fecha_sistema := NULL`; el hoy pasa a la fecha de Colombia (puede ser **anterior** a F) |
| cualquiera → manual sin fecha | `Fecha inválida` |
| cualquiera → cualquier fecha, con el banco **vacío** | permitido (cláusula D5/D-E3-2: el seed puede arrancar ~120 días atrás con funciones reales y avanzar) |

## 4. Objetos nuevos

| Tipo | Objetos |
|---|---|
| Restricción | `ck_reloj_fecha_rango` (`fecha_sistema IS NULL OR` entre 2000-01-01 y 2100-12-31) |
| Permisos | `banco_owner` pierde `UPDATE` de tabla en `reloj` y recibe `UPDATE (usar_fecha_real, fecha_sistema)` (mismo patrón que E2); `banco_app` sin nada; `banco_lector`/`banco_dev` leen `reloj` y ejecutan solo `hoy_banco()` y `ahora_banco()` |
| Funciones públicas de lectura (E3 agrega 14 funciones: de 15 a 29 en total; 2 de lectura, 8 internas y 4 de trigger) | `hoy_banco()`, `ahora_banco()` (`SECURITY DEFINER`, `STABLE`; `EXECUTE` solo `banco_lector`/`banco_dev`) |
| Funciones internas (sin `EXECUTE` para nadie salvo el dueño) | `_ahora_real()` (`clock_timestamp()`, VOLATILE; único punto de inyección de tiempo, **solo en pruebas**), `_hoy_de()` y `_ahora_de()` (puras, `IMMUTABLE`), `_reloj_instantanea()`, `_reloj_vista()`, `_reloj_actualizar(boolean, text)`, `_dias_por_cobrar(date, date)`, `_cuota_vencida(date, boolean, date)` |
| Triggers (12 → 16) | `trg_reloj_a_validar` (BEFORE UPDATE), `trg_reloj_auditar` (AFTER UPDATE), `trg_reloj_borrar` (BEFORE DELETE), `trg_reloj_truncate` (BEFORE TRUNCATE) |
| Vista (5 → 6) | `v_reloj_estado` (lectura: `banco_lector`, `banco_dev`) |
| Defensas | `v_integridad_defensas` verifica los 4 triggers nuevos (existen, habilitados, función correcta), que el dueño no tenga `UPDATE` de tabla sobre `reloj`, que `banco_app` no tenga acceso y que `hoy_banco()`/`ahora_banco()` solo las ejecute el lector/dev. Los event triggers de E2 también auditan ahora los `ALTER TABLE`/`DROP` sobre `reloj` |
| Auditoría | cada cambio **efectivo** del reloj inserta `RELOJ_CAMBIO` en `audit.evento` con `antes`/`despues` (`usar_fecha_real`, `fecha_sistema`, `hoy_banco`); un UPDATE sin cambio no se audita; es atómico con el UPDATE |

### Reglas puras para E7–E9 (sin ninguna decisión financiera)
* `_dias_por_cobrar(ultimo_cobro, hasta)` = los días de `(ultimo_cobro, hasta]`; **vacía** si `hasta ≤ ultimo_cobro`. Así `avanzar_hasta()` no hace nada tras volver a fecha real y **nunca recobra** períodos ya cobrados ni genera rangos negativos.
* `_cuota_vencida(fecha_vencimiento, pagada, hoy)` = `NOT pagada AND fecha_vencimiento < hoy`, **calculada al consultar** (no hay bandera guardada): si el reloj vuelve a una fecha anterior la cuota deja de aparecer vencida. La mora ya registrada se conserva.

## 5. Decisiones aprobadas y cómo quedaron

| ID | Decisión | Implementación |
|---|---|---|
| **D4** — *mecánica del reloj* | **Opción A**, definitiva | Manual solo adelanta (puede igualar o adelantar varias veces: nunca retroceder); real siempre permitido; sin desfase ni fecha guardada en modo real. **Es una garantía técnica de la BD** (trigger `trg_reloj_a_validar`, rige también para el superusuario) |
| **D4-P** — *política de demostraciones* (2026-11-23) | **Capa de USO, distinta de D4.** Un único adelanto por demostración; volver a real siempre permitido; para repetir, restaurar el respaldo inicial | **Documentada, NO implementada como garantía de BD** (sección 14). No cambia ninguna garantía técnica de D4. El análisis de si hace falta algún mecanismo y las alternativas están en 14.5; **decisión pendiente** |
| D-E3-1 | `ahora_banco()` en manual = fecha manual + hora real de Bogotá | `_ahora_de()`; no monotónico en manual (6.5) |
| D-E3-2 | Banco vacío = ninguna fila en `transaccion` | cláusula en `trg_reloj_a_validar`; `v_reloj_estado.banco_vacio` |
| D-E3-3 | Regla del libro `fecha ≤ reloj`, modificando `07` en su sitio | **Comparación DATE contra DATE** (`(fecha AT TIME ZONE 'America/Bogota')::date > hoy_banco()`), no instante contra instante: una pata fechada hoy a las 23:59:59.999999 es del mismo día del banco aunque la hora aún no haya llegado; no depende de la zona de la sesión (probado con 5 zonas). Fechas pasadas permitidas |
| D-E3-4 | Instantánea con `FOR SHARE` | `_reloj_instantanea()`; probado con sesiones reales (`reales/37`) y mutación M39 |
| D-E3-5 | E3 entrega primitivas internas; los `admin_*` son de E11 | `_reloj_actualizar` / `_reloj_vista` |
| **D-E3-6** | Mensaje `Fecha inválida` | Implementado, **PROVISIONAL**: no se presenta como aprobado por el equipo; sigue pendiente de D13. Cambiarlo es editar el literal en `_reloj_actualizar` y `trg_reloj_a_validar` y sus pruebas |
| D-E3-7 | `EXECUTE` de `hoy_banco/ahora_banco` solo lector/dev | probado en SQL y con conexiones reales |
| D-E3-8 | Rango 2000–2100 y auditoría `RELOJ_CAMBIO` | `ck_reloj_fecha_rango`, `trg_reloj_auditar` |
| D-E3-9 | `29_integridad_final.sh` → `99_integridad_final.sh`; `_ahora_real()` sustituible **solo en banco_test** | hecho; la prueba 35 aborta en cualquier otra base |

## 6. Consecuencias funcionales (lo que debe saber el equipo)

### 6.1 Volver a fecha real después de un adelanto (demostración)
*Nota de vocabulario (2026-11-23):* en este documento «simulación» y «adelanto» designan el uso **previsto** del reloj manual: **que administradores y desarrolladores demuestren al profesor cómo se comporta el banco tras cierto tiempo** (política en la sección 14), **no** que los clientes simulen sus finanzas. Lo descrito aquí es la **mecánica** (qué garantiza la BD); la **política** de cuántas veces se adelanta y cómo se repite una demostración es otra capa.

1. **Siempre se puede**, aunque la fecha real sea anterior a la fecha adelantada. El `hoy_banco()` **retrocede** de verdad (p. ej. de 21-dic a 21-nov): no es un fallo, es la salida explícita del adelanto.
2. **`fecha_sistema` queda `NULL`**: no hay desfase ni memoria de la fecha simulada. El contrato `GET /admin/reloj` devuelve `fecha_sistema: null`.
3. **El historial permanece intacto.** Las patas del libro fechadas en el "futuro" simulado **no se borran, revierten ni recalculan** (el libro es inmutable). `v_reloj_estado.patas_fechadas_en_el_futuro` las cuenta; es **informativo, no un error** (`v_integridad_global.ok` sigue `true`).
4. **El adelanto NO es contablemente reversible.** Lo que se cobró (intereses, cuotas, vencimientos) mientras el reloj estaba adelantado **queda cobrado**; volver a real no lo devuelve. Para volver al estado de antes del adelanto **la BD no ofrece ninguna operación**: según la política de demostraciones (sección 14) se **restaura el respaldo del estado inicial** (o, en desarrollo, `reset` + seed).
5. **Nada se cobra dos veces**: los cobros avanzan por `ultimo_cobro`. Con `hoy < ultimo_cobro`, `_dias_por_cobrar` es vacía: `avanzar_hasta` no hace nada, `ultimo_cobro` **nunca retrocede** y, cuando el calendario real alcance esa fecha, solo se cobra lo posterior. Probado con un cobro neutro de 1 peso por día (`tests.cobro_simulado`, que **no** es una fórmula de interés): 8 ciclos adelantar/volver, sin días duplicados, hashes de libro y productos idénticos tras volver.
6. **Las cuotas vencidas se recalculan al consultar.** Una cuota que estaba vencida con el reloj adelantado deja de estarlo al volver; la **mora ya registrada se conserva** (es historia, no estado calculado).
7. **Nuevas operaciones tras volver**: se fechan con el hoy real y entran después de las patas "futuras" por `orden`/`registrado_en`. El orden cronológico de un historial **no** debe inferirse de `fecha` (usar `orden`/`registrado_en`).
8. Mientras el reloj esté adelantado depende de una **decisión del admin**: en manual el paso del tiempo real **no** mueve el hoy del banco; solo el PUT del admin.
9. **Tras volver a real los productos ya devengados hasta la fecha adelantada no devengan más hasta que el calendario real la alcance** (consecuencia de 5): para una demostración es lo esperado; el historial de la demostración queda intacto.

### 6.2 Lo que la mecánica NO impone (y por qué la política de uso es aparte)
Con A, el admin que adelantó el reloj no puede «desadelantarlo» en modo manual; solo volver a real. **La mecánica sí permite** fijar *otra* fecha manual igual o posterior (varios adelantos sucesivos) y volver a adelantar tras haber vuelto a real: ninguna de esas operaciones compromete la integridad (pruebas 31, 34, 35, 37, 38). **Limitar los adelantos a uno por demostración es una política de uso** (sección 14), no una garantía de la BD; si se quisiera una garantía dura sería una decisión explícita (14.5), no un cambio silencioso de D4.

### 6.3 Recomendación para E7 (no implementada)
Que `avanzar_hasta` y los cobros incluyan una **guardia monotónica de `ultimo_cobro`** (`GREATEST(ultimo_cobro, nuevo)`/rechazo de retrocesos) además de `_dias_por_cobrar`: es defensa en profundidad si una función de negocio futura calculara mal el rango. E7 debe además usar `_reloj_instantanea()` al empezar y **nunca** `now()`/`current_date`.

### 6.4 `fecha` vs `registrado_en`
`fecha` es la fecha **de negocio** (la del reloj del banco, puede ser pasada o simulada); `registrado_en` es el instante **real** de inserción. Con el reloj adelantado `fecha ≠ registrado_en` por diseño.

### 6.5 `ahora_banco()` no es monotónico en manual
Es `hoy_banco()` + la hora real de Bogotá. En manual la fecha no cambia pero la hora "da la vuelta" a medianoche real: dos operaciones consecutivas pueden tener `ahora_banco()` decreciente. Por eso el historial se ordena por `transaccion.orden` y `registrado_en`, **nunca** por `fecha`.

## 7. Desviaciones respecto al diseño original (todas con su porqué)

| # | Desviación | Porqué |
|---|---|---|
| 1 | **Sin `desfase_dias`, sin reloj continuo** (opción C del diseño descartada) | D4 = A (tu decisión definitiva). La tabla `reloj` no cambia de forma; solo se añade `ck_reloj_fecha_rango` |
| 2 | **`trg_reloj_unico` se reemplaza por `trg_reloj_borrar` y `trg_reloj_truncate`**; **no hay trigger BEFORE INSERT** | `03_schema.sql` hace `INSERT … ON CONFLICT DO NOTHING` para sembrar la fila; un trigger de INSERT lo rompería (idempotencia). La PK y `ck_reloj_fila_unica` ya impiden una 2.ª fila y la fila no se puede borrar |
| 3 | **No se agregan `patas_con_fecha_futura` ni `reloj_ok` a `v_integridad_global`**; hay `v_reloj_estado.patas_fechadas_en_el_futuro` (informativa) | Esas patas son una **consecuencia esperada** de volver a real (no un error); un control que las marcara fallaría tras cada simulación legítima |
| 4 | `v_reloj_estado` usa `hoy_banco()`/`ahora_banco()` (no `_hoy_de`) | Una vista ejecuta las funciones con los privilegios de quien la consulta; el lector solo puede ejecutar esas dos |
| 5 | Los comentarios del reloj están en `03_schema.sql` (no en `10`) | Si `10` los fijara, reaplicar `03` los pisaría y la prueba de idempotencia (`09`) fallaría |
| 6 | `_reloj_actualizar` recibe la fecha como **texto** | El front manda `''` en modo real; un parámetro `date` fallaría en el driver con un error no-`P0001` (503 en el backend) |
| 7 | Controles de defensa: de 24 a **30** | +4 filas (un control por trigger nuevo) y +2 controles (`reloj` sin `UPDATE` de tabla/sin acceso para app; `EXECUTE` de `hoy_banco/ahora_banco`) |
| 8 | Funciones de arnés nuevas (solo `banco_test`): `tests.cobro_simulado`, `app_reloj`, `app_hoy`, `app_fondear_banco`, `app_fondear_estable`, `app_operacion_lenta`, `app_reloj_aleatorio`; `tests.captura` | Imitar a las futuras funciones de negocio y al backend sin adelantar E4+ |
| 9 | **Ruido de auditoría DDL**: tras `reset` + 3 `apply` hay **11** eventos `DDL` en `audit.evento` (10 en E2) | El `ALTER TABLE … ADD CONSTRAINT ck_reloj_fecha_rango` sobre una tabla protegida se audita (comportamiento pedido); es idempotente y las reaplicaciones no repiten el evento |

## 8. Pruebas y qué demuestran

| Archivo | Qué prueba |
|---|---|
| `30_reloj_funciones` (53) | Funciones puras con instantes inyectados (medianoche de Bogotá 31-dic/1-ene, 29-feb, +30 años), `hoy_banco/ahora_banco` en real y manual con 7 zonas de sesión, forma exacta del contrato (`jsonb`), `EXECUTE` por rol, `_dias_por_cobrar` y `_cuota_vencida` |
| `31_reloj_trigger` (74) | **Matriz completa de transiciones** con el mensaje exacto; 60 ciclos aleatorios contra un modelo; entradas inválidas; UPDATE directo del superusuario/dueño/app/lector/dev/libro; DELETE/TRUNCATE/INSERT; auditoría |
| `32_reloj_banco_vacio` (31) | La cláusula de banco vacío (seed R-120 → R), una sola pata activa la regla completa, y el banco vacío de nuevo tras la cascada |
| `33_reloj_libro` (26) | Regla de fecha del libro: pasado/hoy/mañana, 5 zonas de sesión, reloj manual, volver a real deja patas futuras y no es error, sabotaje detectado |
| `34_reloj_retorno_simulacion` (42) | **Integridad financiera al volver a real**: hashes de libro y productos idénticos, `ultimo_cobro` no retrocede, sin cobros duplicados, mora conservada, cuotas vencidas dinámicas, 8 ciclos |
| `35_reloj_viaje_tiempo` (14) | **Tiempo inyectado** (`_ahora_real()` sustituido solo en `banco_test`, dentro de una transacción): 4000 pasos aleatorios (pasa el tiempo, PUT real/manual, operaciones del libro) contra un modelo independiente |
| `reales/36_reloj_conexiones` (70) | Conexiones TCP reales: `banco_app` sin acceso directo; vía función definer avanzar/retroceder/real; `TimeZone` de la conexión irrelevante; lector/dev leen sin cambiar; operación con reloj +20 y vuelta |
| `reales/37_reloj_concurrencia` (22) | Operación lenta vs cambio de reloj (espera y ve una sola fecha), vuelta a real en vuelo, 3 operaciones en paralelo, tormenta de 6 sesiones (120 cambios aleatorios + 120 operaciones): 0 errores de operaciones, sin deadlocks, sin retrocesos manual→manual aceptados |
| `reales/38_reloj_instantanea` (28) | **Corrección de auditoría (sección 13)**: operación que obtiene el bloqueo sin espera; que espera un bloqueo del admin con el reloj intacto; que espera una modificación del reloj; que **empieza antes de medianoche y obtiene el bloqueo después** (tiempo inyectado); tormenta de cambios de reloj con operaciones multipata autoverificadas (todas las patas con la misma instantánea); y la prohibición de inyectar tiempo fuera de `banco_test`/`banco_mut` |
| `mutaciones.sh` M25–M50 | 26 defensas rotas a propósito (23 del reloj + 3 de la corrección); todas detectadas |

Pruebas de E1/E2 **modificadas** (conservan su significado): `03` (inventario exacto: 29 funciones, 16 triggers, 6 vistas), `08` (privilegios del dueño incluyen `reloj:UPDATE`), `09` (reaplica 00–12), `10` (16 triggers, 28 funciones del dueño, lista `SECURITY DEFINER`, excepciones de `EXECUTE` de lector/dev, 6 vistas), `13` (la prueba de "fechas distintas" usa `now() - interval '1 day'` en vez de un futuro), `16` (la prueba de DDL no protegido usa `parametro`), `helpers.sql` (`sin_triggers_de_usuario()` incluye `reloj`; `tests.captura`), `harness.sql` (funciones de arnés del reloj).

### Cómo se evitan los falsos resultados
* La prueba de tiempo inyectado **no puede correr** en `banco`: aborta si la base no es `banco_test`/`banco_mut`; su `CREATE OR REPLACE` de `_ahora_real()` es transaccional y el `ROLLBACK` lo restaura (la prueba lo comprueba).
* Las pruebas de `reales/` terminan siempre en **modo real** (`trap`), para no contaminar las siguientes.
* Si se ejecutan **cruzando la medianoche de Bogotá** una prueba podría comparar dos "hoy" distintos; las pruebas fijan `R` al inicio. Ante un fallo aislado cerca de las 00:00 (hora de Colombia) repetir la corrida.

## 9. Guía de verificación desde pgAdmin

Prerrequisito: `db\ctl.cmd up` y `db\ctl.cmd apply` (aplica 00–12). Conexiones: **administración (postgres)**, **banco_dev**, **banco_app**, **banco_lector**. Base `banco`, *Tools → Query Tool*.

### A. Inventario (administración)
```sql
-- 1) Los 4 triggers del reloj, habilitados
SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'public.reloj'::regclass AND NOT tgisinternal ORDER BY 1;
-- 2) Funciones del reloj: dueño, SECURITY DEFINER y ACL (solo hoy_banco/ahora_banco tienen EXECUTE para banco_lector)
SELECT proname, pg_get_userbyid(proowner) AS dueno, prosecdef AS definer, proacl
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname ~ 'reloj|hoy_|ahora_|dias_por|cuota_vencida' ORDER BY 1;
-- 3) Estado y restricción de rango
SELECT * FROM public.v_reloj_estado;
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.reloj'::regclass;
-- 4) Privilegios del dueño sobre reloj: solo UPDATE por columna (usar_fecha_real, fecha_sistema)
SELECT grantee, privilege_type, column_name FROM information_schema.column_privileges
 WHERE table_name = 'reloj' AND grantee IN ('banco_owner', 'banco_app', 'banco_lector') AND privilege_type = 'UPDATE';
```
*Esperado:* 4 triggers con `tgenabled = O`; `hoy_banco`/`ahora_banco` con `definer = t` y ACL para `banco_lector`; `_reloj_*` y `trg_reloj_*` sin ACL para otros; `v_reloj_estado` en modo real con `hoy_banco` = fecha de Colombia; `ck_reloj_fecha_rango` presente; `UPDATE` de `banco_owner` solo en las 2 columnas.

### B. Verificación independiente (también con **banco_lector** y **banco_dev**)
```sql
SELECT * FROM public.v_integridad_global;                 -- ok = true
SELECT * FROM public.v_integridad_defensas WHERE NOT ok;  -- 0 filas (ahora 30 controles)
SELECT public.hoy_banco(), public.ahora_banco();          -- fecha de Colombia, hora de Colombia
SELECT * FROM public.v_reloj_estado;
```

### C. Demostración completa sin dejar datos (administración)
Abrir `docs/db/evidencias/03-pgadmin-demo.sql` (en el Query Tool, *Open File* con el explorador de tu equipo, o pegar su contenido) y ejecutar **completo con F5**. Va dentro de `BEGIN … ROLLBACK` y captura cada intento prohibido: los resultados salen como NOTICE en **Messages**. Esperado: 1) estado real; 2) ingreso fechado con `ahora_banco()`; 3) adelantar +30; 4) retroceder a +10 **rechazado** (`El reloj no puede retroceder`); 5) fecha inválida **rechazada**; 6) un ingreso con el reloj en +30 **entra**; 7) una pata fechada un día después del reloj **rechazada**; 8) **volver a real**: `fecha_sistema` vuelve a `NULL`, las 2 patas del ingreso de +30 **permanecen** y se informan como "patas fechadas en el futuro" sin error (en una base con más actividad la cuenta será mayor); 9) una pata nueva fechada en +30 **rechazada** con el reloj real; 10) `UPDATE` directo hacia atrás **rechazado** (también para el superusuario); 11–12) `DELETE`/`TRUNCATE` **rechazados**; 13) la auditoría de los cambios; la última consulta confirma que el reloj quedó como estaba y 0 cuentas de la demo.

### D. Con **banco_app** (el backend): nada directo
```sql
SELECT * FROM public.reloj;                          -- ERROR: permission denied for table reloj
UPDATE public.reloj SET usar_fecha_real = true;      -- ERROR: permission denied
SELECT public.hoy_banco();                           -- ERROR: permission denied for function hoy_banco
SELECT public._reloj_actualizar(true, '');           -- ERROR: permission denied for function _reloj_actualizar
SELECT * FROM public.v_reloj_estado;                 -- ERROR: permission denied for view
```
### E. Con **banco_lector** / **banco_dev**
`SELECT * FROM public.reloj;`, `SELECT public.hoy_banco();` y `SELECT * FROM public.v_reloj_estado;` funcionan; `UPDATE public.reloj …`, `DELETE` y `SELECT public._reloj_actualizar(…)` fallan con *permission denied* (el lector es además de solo lectura por defecto).

### F. Ejecutar los scripts desde pgAdmin
Query Tool → *Open File* → `/work/sql/10_reloj_estructura.sql`, `11_reloj_funciones.sql`, `12_reloj_triggers.sql` → F5 (idempotentes, sin metacomandos de psql). Como **administración (postgres)**.

## 10. Límites (honestidad)

* **Superusuario:** PostgreSQL no se defiende de él (`ALTER TABLE … DISABLE TRIGGER`, `session_replication_role = replica`). Mitigación (igual que en E2): ningún rol de uso diario lo es; los event triggers auditan los `ALTER TABLE`/`DROP TRIGGER` sobre `reloj`; `v_integridad_defensas` detecta triggers apagados, borrados o permisos indebidos. `session_replication_role` no es DDL: no queda en la auditoría.
* **Reloj del servidor:** el modo real depende de la hora del contenedor/servidor y de su sincronización (NTP). Un salto hacia atrás del reloj del sistema no lo vigila PostgreSQL. El instante del banco es el reloj de **pared** (`clock_timestamp()`), no `now()`: una transacción larga ve la fecha del momento en que toma la instantánea (ver sección 13), no la de su inicio.
* **`ahora_banco()` no monotónico en manual** (6.5).
* **`Fecha inválida`** es provisional (D-E3-6/D13).
* **Las funciones de negocio futuras DEBEN** tomar `_reloj_instantanea()` al empezar y usar ese par; si leyeran `hoy_banco()` varias veces o usaran `now()` podrían ver dos fechas o ser rechazadas por la regla del libro. (La prueba 37 muestra la diferencia: con el protocolo estable 0 rechazos.)
* **Mensajes:** solo `El reloj no puede retroceder` es del contrato; el resto son internos (`Libro mayor: …`, `Reloj: …`, P0001).
* **Alcance:** los `admin_leer_reloj`/`admin_set_reloj` y la validación de ADMIN son de E11; aquí solo están las primitivas internas.

## 11. Cómo ejecutar todo

```powershell
db\ctl.cmd up
db\ctl.cmd reset -Yes ; db\ctl.cmd apply ; db\ctl.cmd apply ; db\ctl.cmd apply   # desde cero + 3 aplicaciones
db\ctl.cmd test -Evidence 03-reloj          # suite completa: SQL + conexiones reales + concurrencia
db\ctl.cmd test 35                          # solo la prueba de tiempo inyectado (también filtra reales/)
docker compose -f db\compose.dev.yml exec -T db sh -c "tr -d '\r' < /work/tests/mutaciones/mutaciones.sh | sh -s"
```

## 12. Lista de verificación

- [x] 10–12 aplican desde cero y 3 veces seguidas sin errores; la prueba 09 confirma que el catálogo queda idéntico
- [x] `public` = 11 tablas; `audit.evento` en `audit`
- [x] Opción A: manual solo adelanta; real siempre permitido; sin `desfase_dias`; `fecha_sistema = NULL` en real
- [x] Contrato `GET/PUT /admin/reloj` y mensaje exacto `El reloj no puede retroceder`
- [x] `hoy_banco()` por código en `America/Bogota`, independiente de la zona de sesión/BD
- [x] Regla del libro (DATE contra DATE) y fechas pasadas permitidas
- [x] Volver a real: historial intacto, sin cobros duplicados, `ultimo_cobro` sin retroceso, mora conservada, cuotas vencidas dinámicas
- [x] Concurrencia: una operación ve una sola fecha; sin deadlocks ni timeouts
- [x] Conexiones reales con `banco_app`, `banco_lector`, `banco_dev`
- [x] Mutaciones 50/50; tiempo inyectado solo en `banco_test`/`banco_mut`
- [x] Política de demostraciones (sección 14) documentada como capa de USO separada de la mecánica, sin cambiar scripts ni pruebas
- [x] Documentación, guía de pgAdmin y demo; no se tocó front/backend; sin decisiones financieras adelantadas; sin commits

## 13. Corrección de auditoría: `_reloj_instantanea()` (instante tomado DESPUÉS del bloqueo)

**Observación del auditor.** La función hacía `v_inst := _ahora_real()` en el `DECLARE` (antes del `FOR SHARE`) y `_ahora_real()` era `now()`, el **inicio de la transacción**. Una operación que empieza antes de medianoche, espera el bloqueo del reloj (p. ej. un cambio del admin) y lo obtiene después de medianoche habría devuelto un par `(hoy, ahora)` **del día anterior**.

**Corrección (solo en `11_reloj_funciones.sql`; D4 y el resto de funciones no cambian).**

```sql
-- _reloj_instantanea()  (antes → después)
DECLARE r record; v_inst timestamptz := public._ahora_real();      -- antes: instante ANTES de esperar
BEGIN  SELECT … INTO r FROM public.reloj x WHERE x.id = 1 FOR SHARE; …

DECLARE r record; v_inst timestamptz;                               -- después:
BEGIN
  SELECT x.usar_fecha_real AS usar, x.fecha_sistema AS fecha INTO r FROM public.reloj x WHERE x.id = 1 FOR SHARE;   -- 1) PRIMERO el bloqueo
  v_inst := public._ahora_real();                                                                                   -- 2) DESPUÉS el instante
  hoy := public._hoy_de(r.usar, r.fecha, v_inst);  ahora := public._ahora_de(r.usar, r.fecha, v_inst);              -- 3) un único par
  RETURN NEXT;

-- _ahora_real()
… LANGUAGE sql STABLE … AS $$ SELECT now() $$                           -- antes
… LANGUAGE sql VOLATILE … AS $$ SELECT clock_timestamp() $$             -- después: reloj de pared
```

**Por qué `clock_timestamp()` y por qué en `_ahora_real()` (y no solo en la instantánea).** `now()`/`statement_timestamp()` no sirven: el bloqueo se espera *dentro* de la sentencia. Y la regla del libro compara cada pata con `hoy_banco()`: si solo la instantánea fuera fresca, una operación que cruzó la medianoche esperando fecharía sus patas con el día nuevo y el libro las rechazaría contra un `hoy_banco()` aún basado en `now()`. Con **una sola fuente** (`_ahora_real()` = reloj de pared) `hoy_banco()` nunca está por detrás de la instantánea. Además el `trg_reloj_a_validar` y la auditoría del cambio también usan la hora real (un `UPDATE` del admin que esperó un bloqueo ya no mide el retroceso contra la fecha de inicio de su transacción). Efectos y límites:
* `_ahora_real()` pasa a `VOLATILE` (honesto); `hoy_banco()`/`ahora_banco()` siguen `STABLE` (consistentes dentro de una sentencia) pero ya **no** son idénticos al de `now()`: `ahora_banco()` cae entre el inicio de la transacción y `clock_timestamp()`.
* **Una única pareja `(hoy, ahora)` por operación:** la función de negocio llama a `_reloj_instantanea()` **una vez** al empezar y usa ese par para todas las patas (`_asentar_grupo(ahora, patas)` fecha todo el grupo con el mismo instante y el cuadre exige una sola fecha). Una segunda llamada en la misma transacción tomaría un instante nuevo (queda documentado en el `COMMENT`).
* **Compatibilidad con E4+:** la firma y el uso (`SELECT hoy, ahora FROM _reloj_instantanea()`) no cambian; las funciones que ya la usaban (arnés `tests.app_*`) siguen igual.
* **Inyección de tiempo:** sigue existiendo un único punto, `_ahora_real()`. La prueba 35 (transaccional) y la 38 (con sesiones reales, tabla `tests.reloj_falso`) la sustituyen **solo** si `current_database()` es `banco_test` o `banco_mut`; ambas abortan en cualquier otra base (probado con una base vacía) y restauran la función original (se comprueba). En la base `banco` no existe el esquema `tests` ni la tabla.

**Pruebas obligatorias → dónde están:** obtiene el bloqueo normalmente (`38` A); espera una modificación administrativa (`38` B1/B2); empieza antes de medianoche y adquiere después (`38` C2 con tiempo inyectado: un reloj de pared que pasa de 23:59:58 a 00:00:03 mientras la operación espera ve el día **nuevo**; con el código anterior vería el viejo: mutación M48); cambio de reloj concurrente con operaciones en curso (`37` C y `38` D); todas las patas de una operación con la misma instantánea (`38` C2, C3 y D: `tests.app_op_verificada` autoverifica fecha de cada pata = instantánea = hoy); regresión completa de E1, E2 y E3 (1197 aprobadas). Pruebas existentes **adaptadas** porque comparaban con `now()`: `30` (`ahora_banco()` entre `now()` y `clock_timestamp()`; la instantánea ≤ `ahora_banco()`; `_ahora_real()` es `clock_timestamp()` y `VOLATILE`), `35` (la instantánea coincide con el modelo en cada paso del tiempo inyectado; el final comprueba `clock_timestamp()`).

**Mutaciones nuevas:** M48 (instante antes del bloqueo → detectada por `38`), M49 (`_ahora_real()` vuelve a `now()` → `30`/`38`), M50 (`hoy_banco()` deja de usar `_ahora_real()` → detectada por la inyección).

## 14. Política de demostraciones (capa de USO, distinta de la mecánica del reloj)

> **Aclaración funcional del responsable de BD (2026-11-23), tras conversarla con el equipo.** Este apartado **solo documenta**: no se modificó ningún script SQL, prueba, frontend ni backend, y **no cambia ninguna garantía técnica de E3**.

### 14.1 Propósito
El adelanto temporal del reloj **no** está pensado para que los clientes simulen sus finanzas. Existe para que **administradores y desarrolladores demuestren al profesor cómo se comporta el banco después de transcurrido cierto tiempo** (vencimientos de CDT, intereses, cuotas, mora, pagos…). Es una herramienta de **demostración**, no una función de producto para el cliente.

### 14.2 Flujo aprobado

| # | Paso | Quién / etapa | Qué hace la BD |
|---|---|---|---|
| 1 | Preparar una BD con usuarios, cuentas, créditos, CDT y demás productos | Seed (E14, D5), con funciones reales | La *preparación* puede mover el reloj las veces que haga falta (cláusula de banco vacío, avance por etapas): **no** está sujeta a la restricción |
| 2 | Crear un **respaldo** de ese estado inicial | Procedimiento operativo (14.7; se formaliza en E14) | — (fuera de la BD) |
| 3 | El administrador **adelanta el reloj una sola vez** a la fecha futura deseada | Admin (`PUT /admin/reloj`; primitiva `_reloj_actualizar`, envoltorio de E11) | Mecánica de E3: acepta `F ≥ hoy_banco()` |
| 4 | Realizar las operaciones que demuestran vencimientos, intereses, cuotas, mora, pagos… | Admin/desarrollador; motor lazy E7–E9 | Cobros por rangos de `ultimo_cobro` (`_dias_por_cobrar`), sin duplicar |
| 5 | Al terminar, **volver al modo real** (opcional), con todas las operaciones de la demostración **intactas** | Admin | Siempre permitido; `fecha_sistema = NULL`; el libro es inmutable (6.1) |
| 6 | Para otra demostración desde el estado inicial: **restaurar el respaldo** | Procedimiento operativo | — |

### 14.3 Restricción de uso (política)
* **R1.** Durante una misma demostración **solo se permite un adelanto**. Tras adelantar, **no se establece otra fecha manual**, ni siquiera una posterior a la anterior.
* **R2.** Tampoco se vuelve a adelantar **después de haber vuelto a real** en la misma demostración (un adelanto por demostración).
* **R3.** **Volver al modo real se permite en cualquier momento.**
* **Una nueva demostración exige restaurar el respaldo inicial.** «Una demostración» es el intervalo entre una restauración y la siguiente; la **preparación** del paso 1 queda fuera.

### 14.4 Mecánica (E3) frente a política (demostraciones)

| Aspecto | **Mecánica del reloj** (E3, D4 = A; garantía técnica de la BD) | **Política de demostraciones** (uso; no es garantía de la BD) |
|---|---|---|
| Adelantar el reloj | Permitido si la fecha es **igual o posterior** al hoy del banco; **puede repetirse** (manual → manual hacia adelante) | **Una sola vez** por demostración (R1/R2) |
| Retroceder en modo manual | **Prohibido** (`El reloj no puede retroceder`), también para el superusuario | No aplica (ya no se mueve el reloj manual tras el adelanto) |
| Volver a fecha real | **Siempre permitido**; `fecha_sistema = NULL` | Siempre permitido (R3); fin natural de la demostración |
| Deshacer lo ocurrido durante el adelanto | **Imposible** (libro inmutable; los cobros quedan hechos) | **Restaurar el respaldo** del estado inicial |
| Quién lo hace cumplir | Trigger `trg_reloj_a_validar` (datos, incluso superusuario) y pruebas | **Procedimiento** de demostración; opcionalmente una capa admin (14.5, decisión pendiente) |
| Si se incumple | — | La BD **acepta** un segundo adelanto y **su integridad no se afecta** (probado: matriz de transiciones, 4000 pasos aleatorios, concurrencia, `ultimo_cobro` sin cobros duplicados). Solo se pierde la **reproducibilidad** de la demostración, y se recupera restaurando el respaldo |

### 14.5 ¿Hace falta un mecanismo adicional en PostgreSQL? (análisis; no se implementa nada)

**Hallazgos que condicionan la respuesta**
1. **La integridad no depende de la política.** Cualquier número de adelantos hacia adelante es seguro para la BD; la política protege la **repetibilidad y claridad de la demostración**, no los datos.
2. **R1 no necesita memoria**: «ya hay un adelanto en curso» equivale a `usar_fecha_real = false`, un estado que la tabla `reloj` ya tiene.
3. **R2 sí necesita memoria**: al volver a real `fecha_sistema` queda `NULL` **por diseño** (D4 = A: sin desfase ni rastro), así que la fila `reloj` no recuerda que hubo un adelanto. Recordarlo exige un dato nuevo o una convención.
4. **La preparación (seed, D5) mueve el reloj varias veces con el banco ya con datos** (avance por etapas desde ~120 días atrás). **Un control puesto en el trigger o en `_reloj_actualizar` rompería el seed y las 1197 pruebas de E3**; cualquier control debe estar **fuera de esa primitiva** (capa admin) o **armarse** explícitamente al fijar el respaldo.
5. **Ningún control de BD detiene a un superusuario** (límite ya documentado); la política siempre depende, en último término, del procedimiento.

**Alternativas** (de menor a mayor intervención)

| # | Alternativa | Cubre | Qué cambia | Costo / riesgo | Valoración |
|---|---|---|---|---|---|
| 0 | **Solo política y procedimiento** (esta documentación + lista de verificación 14.7) | R3 y la repetición (restaurar); R1/R2 por disciplina | **Nada** | Un segundo adelanto accidental es posible; su remedio (restaurar) ya forma parte del flujo | ✅ **Recomendada ahora** |
| 1 | **Guarda en la capa admin** (E11, `admin_set_reloj`) y en el selector del front: rechazar una fecha manual si `usar_fecha_real = false` | **R1** (sin estado) | Solo código de E11/front; **E3 intacto**; 1 mensaje nuevo (D13, p. ej. `El reloj ya fue adelantado en esta demostración`) | Muy bajo. No cubre R2. El front ya recibe `usar_fecha_real` en `GET /admin/reloj` (podría deshabilitar el selector sin tocar la BD) | ✅ **Recomendada como opcional al implementar E11**, si el equipo quiere un seguro contra el error en vivo |
| 2 | Deducir «ya hubo adelanto» del **libro** (existe alguna pata con fecha > fecha real de registro) | R1 y R2 *parcialmente* (solo si hubo operaciones) | Una consulta en E11 | Implícita y frágil: un adelanto sin operaciones no cuenta; acopla el reloj a una convención del libro | ❌ No recomendada |
| 3 | **Marca de demostración en `audit.evento`** (evento `DEMO_BASE` colocado por una función solo-seed al fijar el respaldo) + conteo de `RELOJ_CAMBIO` a manual posteriores a la última marca, comprobado en `admin_set_reloj` | **R1 y R2** | Sin tablas, columnas ni triggers nuevos; 1 función solo-seed (E14) y la guarda en E11; tests | Medio: hay que «armar» la política (sin marca no rige) y mantener el procedimiento; sigue sin frenar al superusuario | ⚖️ Solo si el equipo exige **garantía dura de R2** (se decidiría en E14) |
| 4 | **Estado persistente en `reloj`** (columna `adelanto_usado`) + validación en `trg_reloj_a_validar` + reinicio controlado | R1 y R2 | Modifica la tabla, el trigger, las pruebas y los controles de E3 (nueva auditoría de E3) y exige exceptuar el seed | Alto; rompe la simplicidad que se quiere conservar | ❌ No justificado: añadiría un control «por formalidad» |

**Recomendación:** adoptar la **alternativa 0 ahora** (esta documentación) y valorar la **alternativa 1** cuando se diseñe E11, por ser sin estado y sin tocar E3. **R2 queda cubierta por el procedimiento de respaldo/restauración**; solo si el equipo pide garantía dura se estudiaría la alternativa 3. No se añade ningún control de BD en esta etapa.

### 14.6 Consecuencias para otras etapas (anotadas; nada implementado)
* **E7–E9 (motor lazy, CDT, créditos):** las demostraciones usan **un solo salto grande** (p. ej. 30 años con un crédito de 360 cuotas en < 5 s); los cobros por rangos y `ultimo_cobro` ya lo soportan. Las pruebas de E7–E9 pueden seguir ejercitando varios adelantos (es mecánica), pero **la guía de demostración** debe usar uno.
* **E11 (admin):** `admin_set_reloj` envuelve `_reloj_actualizar` con `_validar_admin`; ahí se decidiría la alternativa 1.
* **E14 (seed y QA):** el seed termina con el **reloj en modo real**, el banco **no vacío** y `v_integridad_global.ok`; define y prueba el **procedimiento de respaldo/restauración** (14.7) y, si se eligiera, la marca de la alternativa 3.
* **Front (no se toca):** `Reloj.tsx` hoy permite fijar fechas repetidamente; la política podría reflejarse deshabilitando el selector cuando `usar_fecha_real = false` (decisión del equipo de front).

### 14.7 Procedimiento recomendado de demostración (lista de verificación operativa)
**Preparación (una vez)**
1. Seed con funciones reales; **dejar el reloj en modo real**.
2. Comprobar: `SELECT * FROM v_reloj_estado;` → `usar_fecha_real = true`, `patas_fechadas_en_el_futuro = 0`, `banco_vacio = false`; `SELECT ok FROM v_integridad_global;` → `true`.
3. **Respaldo del estado inicial** — opciones a validar en E14 (no probadas en E3): `pg_dump -Fc banco` (restaurar con `pg_restore --clean --if-exists` sobre la misma BD y el **mismo clúster**, porque los roles `banco_*` son globales y no viajan en el volcado de una BD); BD plantilla (`CREATE DATABASE banco_base TEMPLATE banco`, sin conexiones activas); o instantánea del volumen de Docker. El respaldo incluye la fila de `reloj` y `audit.evento`.

**Demostración**
4. Detener o desconectar el backend si se va a restaurar (cierra el *pool*); confirmar que se parte del estado inicial.
5. **Un único `PUT /admin/reloj`** con la fecha futura; operar y mostrar vencimientos, intereses, cuotas, mora y pagos.
6. (Opcional) volver a **modo real**; las operaciones de la demostración permanecen. **No** fijar otra fecha manual.

**Repetir**
7. Restaurar el respaldo (paso 3), verificar de nuevo el punto 2 y comenzar otra demostración.

### 14.8 Decisiones que quedan registradas

| ID | Decisión | Estado |
|---|---|---|
| D4 (mecánica) | Opción A | ✅ Aprobada e implementada; **sin cambios** |
| D4-P | **Política de demostraciones** (flujo, un único adelanto, volver a real siempre, restaurar para repetir) | ✅ **Documentada** (aclaración del responsable de BD tras hablar con el equipo) |
| P-DEMO-1 | ¿Guarda en la capa admin/front (alternativa 1) al implementar E11? | ⏳ **Pendiente** — recomendación: sí, como opcional |
| P-DEMO-2 | ¿Se exige garantía dura de R2 (alternativa 3)? | ⏳ **Pendiente** — recomendación: no por ahora; cubrir con el procedimiento |
| P-DEMO-3 | Mecanismo concreto de respaldo/restauración (`pg_dump`, plantilla o volumen) | ⏳ Se define y prueba en E14 |

**Estado: E3 aprobada; esta aclaración es solo documental. Detenido a la espera de tu revisión de estos cambios; no se retoma E4 hasta tu orden.**
