# Etapa 2 — Libro mayor y guardias · DISEÑO TÉCNICO (para aprobación)

**Estado:** ✅ diseño **APROBADO** por el responsable de BD (2026-11-21, con las seis decisiones D-E2-1…6 y sus precisiones) e **IMPLEMENTADO**. Lo entregado y las **desviaciones** respecto a este diseño (con su porqué) están en [02-libro-mayor.md](02-libro-mayor.md); lo que sigue es el diseño tal como se aprobó. Sin commits.

> Precisiones de la aprobación: D-E2-1 (los grupos de crédito sin plantilla exigen mismo crédito, misma cuenta propietaria, sin transferencias y con cuadre); `banco_owner` sigue NOLOGIN y ningún rol de aplicación puede asumirlo; permisos `SELECT` mínimos de `banco_ledger`; `ledger_probe` con eliminación garantizada; las pruebas de FK no usan `session_replication_role = replica`. No se toca `front/`, backend ni archivos de otros integrantes. No se decide nada financiero congelado (D1, D4, D6, D7, D8, D10–D13).

Parte de: diseño consolidado v3 (secciones C.4 y D.6; D2 validada) y de la [E1 aprobada](01-esquema.md).

---

## 0. Resumen en una página

E2 convierte la tabla `transaccion` (hoy solo estructura) en un **libro mayor protegido**. Tras E2 ocurre lo siguiente, y nada más:

1. **Los saldos solo se mueven insertando patas en el libro.** `cuenta.balance`, `bolsillo.balance`, `cdt.generado_acumulado` y `credito.capital_pendiente` solo los modifica un trigger del libro (`banco_ledger`), y un *guardia* rechaza cualquier otro `UPDATE`, incluso del propietario o de un superusuario.
2. **Cada grupo de patas debe cuadrar** (ΣD = ΣC), tener una **forma contable válida** (plantilla) y estar completo en **una sola transacción**. Se verifica en el `COMMIT` y, para dar errores limpios, también dentro de la función de escritura.
3. **El historial es inmutable:** sin `UPDATE`, sin `TRUNCATE`, y el `DELETE` solo existe como efecto de borrar la cuenta (cascada). Cada pata queda con su hora real de registro y el id de la transacción.
4. **Concurrencia:** un único protocolo de bloqueo (cuentas en orden de id) elimina los *deadlocks* entre transferencias cruzadas. Validado con un experimento.
5. **Verificación independiente:** vistas `v_integridad_*` recalculan todo desde las patas y detectan cualquier desvío, incluidas las defensas desactivadas.
6. **Pruebas con conexiones reales** (`banco_app`; y `banco_ledger` mediante un rol-sonda de solo pruebas, porque `banco_ledger` es `NOLOGIN` por diseño), concurrencia con procesos `psql` en paralelo, pruebas aleatorias y de mutación.

Necesito 6 decisiones tuyas (sección 12). Las dos más importantes: **(D-E2-1)** si las plantillas de `CREDITO_CUOTA/ABONO/MORA` esperan a D7, y **(D-E2-2)** añadir dos columnas de trazabilidad a `transaccion`.

---

## 1. Alcance

| Entra en E2 | No entra (se queda para su etapa) |
|---|---|
| Triggers del libro, guardias de saldos, inmutabilidad, cuadre y plantillas | Funciones de negocio (`hacer_transferencia`, `crear_bolsillo`, …): E4+ |
| Función interna `_asentar_grupo` (único escritor autorizado) | Intereses, cuotas, mora, abonos, plan francés: E7–E9 (D1, D7) |
| Constraint trigger de invariantes del CDT | Reloj y `hoy_banco()`: E3 (D4). El libro **no** valida `fecha` contra el reloj |
| Auditoría automática del borrado de cuentas; event trigger de DDL | `admin_borrar_usuario` y demás funciones admin: E11 |
| Vistas `v_integridad_*` | Procedimiento `sp_verificar_integridad`: E13 (solo envolverá estas vistas) |
| Permisos adicionales (el dueño pierde `UPDATE` de acumuladores) | Vistas del contrato (`vista_*`, `v_transaccion_usuario`): E10 |
| Pruebas: SQL, conexiones reales, concurrencia, aleatorias, mutación | Seed y datos de demo: E14 |

---

## 2. Validación técnica previa (laboratorio `e2_lab`, ya eliminado)

Antes de proponer el diseño probé en una base desechable los puntos de los que depende. Resultados reales:

| # | Suposición | Resultado | Consecuencia en el diseño |
|---|---|---|---|
| L1 | Una función `SECURITY DEFINER` de `banco_ledger` ve `current_user = banco_ledger` y `pg_trigger_depth() = 1`; el guardia (función normal, *invoker*) que salta al actualizar ve `current_user = banco_ledger` y **profundidad 2** | ✅ confirmado | Regla de confianza: `current_user = 'banco_ledger' AND pg_trigger_depth() > 1`. **El guardia debe ser `SECURITY INVOKER`** (si fuera `DEFINER` vería al dueño) |
| L2 | `UPDATE cuenta SET balance=…` directo: como `banco_ledger` (tiene el privilegio) y como **superusuario** → el guardia lo rechaza (profundidad 1) | ✅ | El guardia es una barrera independiente de los privilegios |
| L3 | Revocar **todo** `UPDATE` de `cuenta` al propietario rompe los `INSERT` en tablas hijas: la comprobación de FK usa `SELECT … FOR KEY SHARE`, que exige privilegio `UPDATE` sobre alguna columna, y corre con los privilegios del dueño de la tabla padre (`permission denied for table cuenta`) | ⚠️ **descubierto** | El dueño conserva `UPDATE` **solo sobre columnas inocuas** (nunca sobre acumuladores). Con esa concesión, el dueño sí puede bloquear filas (`FOR NO KEY UPDATE`) |
| L4 | `FOR NO KEY UPDATE` sobre `cuenta` **no** bloquea un `INSERT` hijo (0,9 s con la fila bloqueada 4 s); `FOR UPDATE` sí (3,9 s) | ✅ | Todos los bloqueos del libro son `FOR NO KEY UPDATE` (no frenan FKs ajenas) |
| L5 | Deadlock real entre dos transferencias cruzadas 2→3 ∥ 3→2 con inserción "natural" (origen primero): `deadlock detected`. Con inserción en **orden de id**: las dos terminan | ✅ | El protocolo de bloqueo (sección 8) es imprescindible; `_asentar_grupo` lo impone |
| L6 | `SET CONSTRAINTS <trigger> IMMEDIATE` dentro de una función dispara el cuadre de inmediato; el error se puede capturar como `P0001` y todo revierte; con `COMMIT` directo la pata suelta falla **en el COMMIT** y el saldo queda intacto | ✅ | Doble red: error limpio dentro de la función + garantía en el `COMMIT` |
| L7 | En la cascada de `DELETE FROM usuario`, el `BEFORE DELETE` de `transaccion` corre a profundidad 2 y **la cuenta ya no existe**; un `DELETE` directo corre a profundidad 1 y la cuenta existe | ✅ | Regla de borrado: solo se permite si la cuenta de la pata ya no existe. No depende de variables de sesión |
| L8 | Orden de disparo de triggers del mismo evento: alfabético por nombre | ✅ | Los nombres fijan el orden (`…_a_…`, `…_b_…`, `trg_zz_…` al final) |
| L9 | `ALTER FUNCTION … OWNER TO banco_ledger` desde superusuario funciona sin concederle `CREATE` | ✅ | Los scripts (que corren como superusuario) no necesitan ampliar privilegios de `banco_ledger` |

**Consecuencia secundaria de L7:** al borrar a un cliente, la pata del *otro* cliente de una transferencia queda sola (sin su pareja). Es esperado (el diseño ya guarda la contraparte como texto) y las vistas de integridad lo distinguen de un error real (sección 9).

---

## 3. Defensa en capas

| Capa | Mecanismo | Frena | ¿Depende de otra capa? |
|---|---|---|---|
| 1 Privilegios | Nadie tiene `INSERT` en `transaccion` salvo el propietario; el propietario pierde `UPDATE` sobre acumuladores y sobre el libro; `banco_app` no tiene nada | Roles de uso diario | No |
| 2 Guardia | `trg_zz_proteger_*` (invoker): un cambio de acumulador solo es válido con `current_user='banco_ledger'` y profundidad > 1 | Propietario con función defectuosa, `banco_ledger` suelto, superusuario | No |
| 3 Trigger del libro | `trg_transaccion_b_aplicar` (dueño `banco_ledger`): único que calcula y aplica saldos, bajo bloqueo | Saldo negativo, pata sobre contenedor ajeno | Usa 1 y 2 |
| 4 Cuadre | Constraint trigger diferido: ΣD=ΣC, plantilla, sellado, cuenta única/par `ENVIO`/`RECIBO` | Grupos incompletos o inventados, dinero entre cuentas fuera de una transferencia | No |
| 5 Inmutabilidad | `UPDATE`/`TRUNCATE` siempre rechazados; `DELETE` solo por cascada de cuenta | Reescribir historia | No |
| 6 Trazabilidad | `registrado_en`, `tx_id`, auditoría del borrado de cuenta, event trigger de DDL | Cambios sin rastro | — |
| 7 Detección | Vistas `v_integridad_*`, `v_integridad_defensas` recalculan y comprueban que las defensas siguen activas | Lo que escape (p. ej. superusuario) | Independiente |

**Límite honesto (igual que en el diseño v3, D.6.6):** PostgreSQL no se defiende de un superusuario (`ALTER TABLE … DISABLE TRIGGER`, `session_replication_role = replica`). Mitigaciones: ninguna cuenta de uso diario lo es; el event trigger audita los `ALTER TABLE`; la capa 7 detecta triggers desactivados y desvíos de saldo.

---

## 4. Cambios en el esquema (script `06`)

> **Esto modifica una tabla de la E1 aprobada** (por eso lo pregunto: D-E2-2). Se hace con `ALTER TABLE … ADD COLUMN IF NOT EXISTS` en un script nuevo; `03_schema.sql` no se toca.

| Columna nueva en `transaccion` | Tipo | Para qué |
|---|---|---|
| `registrado_en` | `timestamptz NOT NULL DEFAULT clock_timestamp()` | **Hora real de registro**, distinta de `fecha` (hora de negocio, que el reloj manual puede adelantar). El trigger la fuerza: el llamador no puede falsearla |
| `tx_id` | `xid8 NOT NULL DEFAULT pg_current_xact_id()` | **Identifica la transacción de base de datos**. Sirve para (a) *sellar* el grupo (todas sus patas en la misma transacción) y (b) auditar qué patas nacieron juntas |

No se añaden tablas (siguen 11 + `audit.evento`) ni se cambian las 37 combinaciones de la matriz.

**Consecuencia para créditos (a aprobar, D-E2-5):** `credito` se inserta con `capital_pendiente = 0` y la pata `CREDITO_DESEMBOLSO` (`CREDITO E`) lo sube a `monto`. Es lo que ya dicta D2 ("pasivo ↑: capital_pendiente +M"); el guardia de inserción exige acumuladores en 0 al crear el contenedor, de modo que ninguno nace con saldo "de la nada".

---

## 5. Objetos que se crean

Numeración: E1 usó `01–05`; E2 usa `06–09` (la numeración prevista en D.1 para etapas posteriores se desplaza; se renumera en su momento, sin impacto funcional).

| Script | Contenido |
|---|---|
| `06_libro_mayor_estructura.sql` | Columnas nuevas, permisos de dueño/ledger sobre acumuladores, `COMMENT`s |
| `07_libro_mayor_funciones.sql` | Funciones de trigger, `_asentar_grupo`, `_plantillas_validas`, auditoría |
| `08_libro_mayor_triggers.sql` | Todos los triggers, constraint triggers y el event trigger |
| `09_integridad.sql` | Vistas `v_integridad_*` + permisos de lectura |

### 5.1 Funciones

| Función | Dueño | Modo | Rol |
|---|---|---|---|
| `_asentar_grupo(p_fecha timestamptz, p_patas jsonb) → uuid` | `banco_owner` | `SECURITY DEFINER`, `search_path = public, pg_temp` | **Único escritor autorizado** del libro (sección 6.1). Sin `EXECUTE` para nadie más (ni `banco_app`) |
| `trg_transaccion_a_validar()` | `banco_owner` | invoker | `BEFORE INSERT`: fuerza `registrado_en`/`tx_id`, anula saldos del llamador, sella el grupo, comprueba propiedad de contenedores |
| `trg_transaccion_b_aplicar()` | **`banco_ledger`** | `SECURITY DEFINER` | `BEFORE INSERT`: bloquea el contenedor, calcula saldo previo/posterior, actualiza el acumulador (6.2) |
| `ct_transaccion_cuadre()` | `banco_owner` | invoker | Constraint trigger diferido: invariantes del grupo (6.3) |
| `ct_cdt_inversion()` | `banco_owner` | invoker | Constraint trigger diferido: invariantes del CDT (6.4) |
| `trg_transaccion_inmutable()` / `trg_transaccion_truncate()` | `banco_owner` | invoker | Inmutabilidad (6.5) |
| `trg_zz_proteger_cuenta/bolsillo/cdt/credito()` | `banco_owner` | **invoker (obligatorio)** | Guardias de acumuladores + columnas inmutables + ciclo de vida (6.6) |
| `trg_cuenta_auditar_borrado()` | `banco_owner` | `SECURITY DEFINER` | `BEFORE DELETE` en `cuenta`: deja en `audit.evento` el estado contable de lo que se destruye |
| `_plantillas_validas()` | `banco_owner` | `IMMUTABLE` | Catálogo de formas de grupo (6.3) |
| `trg_evento_ddl()` | `banco_owner` | `SECURITY DEFINER` | Event trigger: registra `ALTER TABLE`/`DROP TRIGGER` sobre objetos protegidos |

Todas llevan `COMMENT ON FUNCTION` (visible en pgAdmin) y `search_path` fijado las de `SECURITY DEFINER`.

### 5.2 Triggers (el nombre fija el orden de disparo; L8)

| Tabla | Trigger | Momento | Función |
|---|---|---|---|
| `transaccion` | `trg_transaccion_a_validar` | BEFORE INSERT, por fila | validar |
| `transaccion` | `trg_transaccion_b_aplicar` | BEFORE INSERT, por fila | aplicar (ledger) |
| `transaccion` | `ct_transaccion_cuadre` | AFTER INSERT, por fila, **CONSTRAINT, DEFERRABLE INITIALLY DEFERRED** | cuadre |
| `transaccion` | `ct_transaccion_cdt` | ídem, `WHEN (NEW.cdt_id IS NOT NULL)` | ct_cdt_inversion |
| `cdt` | `ct_cdt_inversion` | AFTER INSERT OR UPDATE (estado, generado_acumulado), CONSTRAINT diferido | ct_cdt_inversion |
| `transaccion` | `trg_transaccion_inmutable` | BEFORE UPDATE OR DELETE, por fila | inmutable |
| `transaccion` | `trg_transaccion_truncate` | BEFORE TRUNCATE, por sentencia | rechaza siempre |
| `cuenta`, `bolsillo`, `cdt`, `credito` | `trg_zz_proteger_<tabla>` | BEFORE INSERT OR UPDATE, por fila (corre **último**) | guardia |
| `cuenta` | `trg_cuenta_auditar_borrado` | BEFORE DELETE, por fila | auditoría |
| (base) | `evt_ddl_protegido` | EVENT TRIGGER `ddl_command_end` (`ALTER TABLE`) y `sql_drop` (`DROP TRIGGER`) | trg_evento_ddl |

---

## 6. Algoritmos

### 6.1 `_asentar_grupo` — el único camino de escritura

Entrada: `p_fecha` y `p_patas jsonb` = arreglo de `{tipo, contenedor, sentido, monto, cuenta_id, bolsillo_id?, cdt_id?, credito_id?, nota?, contraparte_nombre?, contraparte_cuenta?}`. Salida: `grupo_id` (uuid nuevo).

1. Exige `READ COMMITTED` (si no, error: `FOR NO KEY UPDATE` en otros niveles da `40001`, que el backend vería como 503).
2. Convierte el JSON a filas **con tipos** (`monto` al dominio `dinero`, enums): un valor mal formado falla aquí con `P0001` y mensaje claro, no con un error técnico.
3. Exige ≥ 2 patas.
4. **Bloqueo raíz:** `SELECT … FROM cuenta WHERE id = ANY(cuentas distintas) ORDER BY id FOR NO KEY UPDATE`. Falla si falta alguna cuenta.
5. Inserta las patas en orden determinista `(cuenta_id, contenedor, id de contenedor, sentido)` con un `grupo_id` común. Cada inserción dispara validar → aplicar.
6. `SET CONSTRAINTS ct_transaccion_cuadre, ct_transaccion_cdt IMMEDIATE; … DEFERRED` ⇒ el cuadre y las invariantes del CDT se evalúan **aquí** (errores limpios, capturables), no solo al `COMMIT`.
7. Devuelve `grupo_id`. Cualquier excepción deshace **todo** el grupo (atomicidad).

Los llamadores (E4+) construyen las patas; **no calculan saldos**: el libro los fija.

### 6.2 `trg_transaccion_b_aplicar` (dueño `banco_ledger`)

Para cada pata, tras `trg_transaccion_a_validar`:

| Contenedor | Qué hace |
|---|---|
| `CUENTA` | Lee `balance` con `FOR NO KEY UPDATE`; `previo := balance`; `posterior := previo ± monto`; si `posterior < 0` ⇒ **`Saldo insuficiente`** (`P0001`, mensaje del contrato); `UPDATE cuenta SET balance = posterior` |
| `BOLSILLO` | Igual sobre `bolsillo.balance` |
| `CREDITO` | Igual sobre `credito.capital_pendiente`; si `< 0` ⇒ error interno (`Libro mayor: capital pendiente insuficiente`) |
| `CDT` | Si el tipo es `INTERES_CDT`: `generado_acumulado += monto`. `CDT_CREACION`/`CDT_VENCIMIENTO` no tocan acumuladores (el principal es `cdt.monto`, inmutable). Saldos `NULL` |
| `RESULTADO` | No hay acumulador (derivado). Saldos `NULL` |

Detalles: el acumulador se lee **después** de tomar el bloqueo (en `READ COMMITTED` devuelve la última versión confirmada), de modo que dos retiros simultáneos no pueden gastar el mismo dinero (prueba de concurrencia 8.3). El `UPDATE` ocurre dentro del contexto confiable (L1), por eso pasa el guardia. Los saldos que traiga la pata se **descartan**: los fija el libro.

### 6.3 Cuadre del grupo — `ct_transaccion_cuadre` (diferido)

Se evalúa por cada pata insertada (≈2–3 consultas indexadas por `ix_transaccion_grupo`). Para el grupo de `NEW.grupo_id` exige **todo** lo siguiente:

| Regla | Contenido |
|---|---|
| G1 | ≥ 2 patas |
| G2 | **Cuadre:** `Σ monto(lado='D') = Σ monto(lado='C')` |
| G3 | **Sellado:** todas las patas con el mismo `tx_id` (no se puede ampliar un grupo ya confirmado; lo impone también `trg_transaccion_a_validar` al insertar) |
| G4 | Mismo `fecha` en todas las patas |
| G5 | **Dinero entre cuentas:** un grupo con patas en más de una `cuenta_id` solo es válido si es exactamente la plantilla `ENVIO`/`RECIBO` de dos cuentas distintas |
| G6 | **Plantilla:** el conjunto de `(tipo, contenedor, sentido)` del grupo coincide con una de las formas de `_plantillas_validas()`, más reglas de coherencia (misma referencia de producto en las dos patas; en `BOLSO_MOVIMIENTO`, bolsillos distintos; en `ENVIO`/`RECIBO`, `contraparte_cuenta` de cada pata = número de cuenta de la otra) |

**Plantillas definidas en E2 (15):** `ENVIO` desde cuenta y desde bolsillo (con `RECIBO`), `BOLSO_INGRESO`, `BOLSO_RETIRO`, `BOLSO_MOVIMIENTO`, `INTERES_BOLSO`, `CDT_CREACION`, `INTERES_CDT`, `CDT_VENCIMIENTO`, `CREDITO_DESEMBOLSO`, y las cuatro de "banco" (`INGRESO_SIMULADO`, `BONO_REFERIDO`, `DEPOSITO_BANCO`, `AJUSTE_ADMIN` en sus dos signos). Todas salen de la matriz validada en C.4: **solo fijan qué patas existen**; los montos los obliga a cuadrar G2.

**Pendiente de decisión (D-E2-1):** `CREDITO_CUOTA`, `CREDITO_ABONO` y `CREDITO_MORA` dependen de D7 (cómo se cobran mora e interés del abono). Mi recomendación es **no fijar su plantilla todavía**: mientras tanto se les aplican G1–G5 y la matriz por pata (así nunca mueven dinero entre cuentas ni descuadran), y `v_integridad_grupos` los lista como "sin plantilla". La plantilla se añade en E9 al cerrar D7.

### 6.4 CDT — `ct_cdt_inversion` (diferido)

Se evalúa al confirmar cuando el CDT es nuevo, cambia su `estado`/`generado_acumulado` o recibe patas:

* `Σ patas CDT (E − S) = CASE estado WHEN 'ACTIVO' THEN monto + generado_acumulado ELSE 0 END`.
* `generado_acumulado = Σ patas INTERES_CDT`.

Efecto: un CDT no puede crearse sin su pata de apertura, ni cerrarse sin devolver exactamente `monto + generado`, ni devolver de más o de menos. (`estado` lo cambia la función de negocio; el libro verifica que quedó coherente.) No fija ninguna fórmula de interés.

### 6.5 Inmutabilidad — `trg_transaccion_inmutable` / `truncate`

* `UPDATE` ⇒ siempre error.
* `TRUNCATE` ⇒ siempre error (también en cascada: `TRUNCATE usuario CASCADE`).
* `DELETE` ⇒ solo si **la cuenta de la pata ya no existe** (cascada, L7); si no, error. No usa variables de sesión.
* Capa de privilegios: el dueño pierde `UPDATE` y `TRUNCATE` sobre `transaccion` (conserva `DELETE` porque la cascada lo necesita).

### 6.6 Guardias de acumuladores y ciclo de vida — `trg_zz_proteger_*`

Corren **al final** de los BEFORE (así ven el valor definitivo). Comunes: al `INSERT`, el acumulador debe ser `0`; al `UPDATE`, cambiarlo solo es válido en contexto confiable (L1).

| Tabla | Columnas inmutables | Ciclo de vida |
|---|---|---|
| `cuenta` | `id, usuario_id, rol, numero_cuenta, creado_en` | — |
| `bolsillo` | `id, cuenta_id, creado_en` | — |
| `cdt` | `id, cuenta_id, nombre, monto, tasa_anual, plazo_dias, fecha_inicio, fecha_fin`; `definicion_id` solo puede pasar a `NULL` (la FK `SET NULL`) | `ACTIVO → CERRADO`, sin reabrir |
| `credito` | `id, cuenta_id, producto_id, monto, tasa_anual, plazo_meses, fecha_desembolso` | `ACTIVO → PAGADO`, sin reabrir |

Esto es la regla I4 del diseño (tasa/plazo/monto copiados al crear = snapshot contractual). No toca `mora_acumulada`, `fecha_interes` ni `cuota` (decisiones D7/D1).

### 6.7 Auditoría y DDL

* `trg_cuenta_auditar_borrado`: antes de borrar una cuenta (directamente o por la cascada de borrar al usuario) inserta en `audit.evento` la acción `CUENTA_BORRADA` con `antes = {usuario_id, numero_cuenta, activos:{cuenta,bolsillos,cdt}, pasivos, resultado, transf_neto, patas}` y el actor desde `banco.actor` (**solo atribución, no control de seguridad**). Así el dinero destruido queda trazado sin depender de que E11 lo recuerde, y permite conciliar I5g.
* Event trigger `evt_ddl_protegido`: registra `ALTER TABLE` (incluye `DISABLE TRIGGER`) y `DROP TRIGGER` sobre las tablas protegidas. Las reaplicaciones de los scripts también quedan registradas (ruido esperado, documentado).

---

## 7. Invariantes y cómo se garantizan y se verifican

| # | Invariante | Garantía | Verificación |
|---|---|---|---|
| I1 | Cada acumulador = Σ(±monto) de sus patas; `generado_acumulado` = Σ `INTERES_CDT` | Triggers 6.2 + guardias 6.6 | `v_integridad_saldos` |
| I2 | `balance`, `bolsillo`, `capital_pendiente` ≥ 0 | CHECK + trigger (`Saldo insuficiente`) | idem |
| I3 | Cada grupo cuadra (ΣD=ΣC), con forma válida, sellado y misma fecha | 6.3 (diferido + inmediato en `_asentar_grupo`) | `v_integridad_grupos` |
| I4 | Campos contractuales inmutables, ciclo de vida sin reabrir | 6.6 | pruebas |
| I5u | Por usuario: `Activos − Pasivos = Resultado + TransfNeto` | Consecuencia de I1+I3 | `v_integridad_usuario` |
| I5g | `Σ_clientes TransfNeto` = 0 salvo cuentas borradas (auditadas) | Consecuencia + 6.7 | `v_integridad_global` |
| I6 | Libro inmutable; solo cae por cascada de cuenta | 6.5 | pruebas + mutaciones |
| I7 | El dinero solo cruza cuentas en un par `ENVIO`/`RECIBO` | G5 | `v_integridad_grupos` |
| I8 | Ningún contenedor nace con saldo; ninguna pata apunta a contenedor ajeno | Guardia de inserción + 6.1 validar | pruebas |
| I9 | Las defensas siguen activas | — | `v_integridad_defensas` |

**Vistas (script 09, dueño `banco_owner`, `SELECT` para `banco_lector`):** cada una es **una sola sentencia**, así que lee un único *snapshot* aunque haya escrituras concurrentes (sin falsos positivos).

* `v_integridad_saldos`: por contenedor, almacenado vs suma de patas, diferencia, `ok`.
* `v_integridad_grupos`: por grupo, ΣD, ΣC, nº de patas, plantilla detectada o "sin plantilla" (créditos pendientes de D7), `ok`. Un grupo `ENVIO`/`RECIBO` con **una sola pata** se clasifica `HUERFANO_POR_BORRADO` (informativo) **solo si** el `contraparte_cuenta` de esa pata ya no existe en `cuenta`; si la cuenta contraria existe, es un error real.
* `v_integridad_usuario` (I5u), `v_integridad_global` (I5g y conteos; añade el efecto de las cuentas borradas leído de `audit.evento`).
* `v_integridad_defensas`: ¿están **habilitados** todos los triggers esperados (`pg_trigger.tgenabled`)? ¿el dueño y `banco_app` no tienen `UPDATE` sobre acumuladores? ¿existe el event trigger? ¿`banco_ledger` conserva exactamente sus 4 columnas? Una fila por control con `ok`.

---

## 8. Concurrencia y atomicidad

### 8.1 Protocolo de bloqueo (obligatorio, validado en L4/L5)

1. **Raíz:** la fila de `cuenta`, `FOR NO KEY UPDATE`, **en orden ascendente de id**, en `_asentar_grupo` antes de insertar nada.
2. Con la raíz tomada, el resto de contenedores de esa cuenta (bolsillo, CDT, crédito) solo los toca quien la sostiene ⇒ no hay contienda ni ciclos entre contenedores.
3. El trigger vuelve a bloquear el contenedor (no-op si ya lo tiene): protege también los `INSERT` directos (que no son el camino sancionado).
4. Todo en `READ COMMITTED` (verificado en el paso 1 de `_asentar_grupo`).
5. `banco_app` ya tiene `lock_timeout=3s` y `statement_timeout=5s` (E1): un bloqueo largo falla con `55P03`; las funciones de negocio (E5+) lo convertirán a `P0001` para que el backend no lo vea como 503. El libro no inventa ese mensaje (decisión del equipo, D13).

### 8.2 Orden de las patas

`orden` (identity) se asigna al insertar. Como las operaciones de una cuenta están serializadas por la raíz, **`orden` es monótono por cuenta**, que es lo que usa el historial (`ix_transaccion_cuenta_orden`). Entre cuentas distintas puede no coincidir con el orden de `COMMIT`, y no importa.

### 8.3 Atomicidad

Una llamada de negocio = una sentencia = una transacción: o entran **todas** las patas y se actualizan **todos** los saldos, o no entra nada (pruebas con fallo a mitad de grupo, con el grupo ya a medio insertar, y con la conexión cortada antes del `COMMIT`). No hay transacciones autónomas ni `COMMIT` dentro de las funciones.

---

## 9. Permisos finales (cambios de E2)

| Objeto | Rol | Antes (E1) | E2 |
|---|---|---|---|
| `cuenta`, `bolsillo`, `cdt`, `credito` | `banco_owner` | todo | **pierde `UPDATE` de tabla**; recibe `UPDATE` solo de columnas no-acumulador: `cuenta(creado_en)`*, `bolsillo(nombre, ultimo_cobro)`, `cdt(ultimo_cobro, estado)`, `credito(descuento_automatico, mora_acumulada, fecha_interes, estado)` |
| `transaccion` | `banco_owner` | todo | pierde `UPDATE` y `TRUNCATE` (conserva `INSERT`, `SELECT`, `DELETE`) |
| acumuladores | `banco_ledger` | `UPDATE(col)` | igual (sin cambios) |
| `_asentar_grupo` y demás funciones | `banco_app`, `banco_dev`, `banco_lector` | — | **sin `EXECUTE`** (todas internas) |
| `v_integridad_*` | `banco_lector` (y `banco_dev` por herencia) | — | `SELECT` |

\* `cuenta(creado_en)` existe solo para que las FK puedan bloquear filas (L3); el guardia impide modificarla. Quedará documentado en `COMMENT`.
`mora_acumulada` sigue editable por el dueño hasta que D7 decida qué es (no se adelanta nada).

**Impacto en pruebas de E1:** hoy las pruebas insertan filas de `transaccion` sueltas y con saldos manuales para probar los CHECK. Con los triggers de E2 eso ya no es posible directamente. Se adaptan **solo** las pruebas afectadas (`04`, `05`, `06`, `09` y la aserción "E1 no tiene triggers" de `03`) haciendo que esas sesiones de prueba usen `SET session_replication_role = replica` (solo en `banco_test`, como superusuario) para ejercitar los CHECK sin los triggers; el comportamiento con triggers se prueba en archivos nuevos. Las 349 aserciones actuales se conservan y se documenta cada adaptación.

---

## 10. Estrategia de pruebas

| Archivo (nuevo) | Qué prueba | Aserciones aprox. |
|---|---|---|
| `10_libro_triggers` | Orden de disparo, estado habilitado, dueños, `SECURITY` de cada función, `COMMENT` en todo | 25 |
| `11_libro_guardias` | `UPDATE balance` directo rechazado como dueño, `banco_ledger`, superusuario; inserción con saldo ≠ 0 rechazada; columnas inmutables; ciclo de vida CDT/crédito; el dueño sí puede actualizar sus columnas permitidas | 40 |
| `12_libro_asentar` | Las 15 plantillas válidas mueven saldos exactos; saldo previo/posterior correcto; `Saldo insuficiente`; contenedor ajeno; JSON mal formado; mismo grupo en otra transacción | 55 |
| `13_libro_cuadre` | Grupos descuadrados, sin plantilla, dinero cruzando cuentas, `contraparte_cuenta` inconsistente, fechas distintas, grupo ampliado después; fallo al `COMMIT` en inserción directa | 40 |
| `14_libro_cdt` | Apertura sin pata, vencimiento de más/de menos, interés fuera de pata | 15 |
| `15_libro_inmutable` | `UPDATE`/`TRUNCATE` (incluido en cascada), `DELETE` directo; borrado de usuario completo; auditoría `CUENTA_BORRADA` con totales correctos; pata huérfana de pareja | 25 |
| `16_integridad_vistas` | Las vistas dan 0 desvíos en estado sano **y detectan** cada falla inducida (saldo alterado como superusuario, trigger desactivado, pata huérfana real vs por borrado) | 30 |
| `17_libro_aleatorio` | Generador con semilla fija: 20 000 grupos válidos de todas las plantillas + 5 000 inválidos (todos rechazados); al final todas las vistas en 0 y conservación global | 6 |
| `18_libro_aislamiento` | Rechazo fuera de `READ COMMITTED`; rendimiento (10 000 patas) y `EXPLAIN` del cuadre usando `ix_transaccion_grupo` | 8 |
| **Conexiones reales** (`conexiones/`) | Ver abajo | 35 |
| **Concurrencia** (`concurrencia/*.sh`) | Ver abajo | 12 escenarios |
| **Mutación** | ≥ 14 mutaciones (quitar guardia, desactivar trigger de aplicar, quitar cuadre, quitar sellado, devolver `UPDATE` al dueño, `depth>0`, permitir `DELETE` directo, …); cada una debe hacer fallar una prueba | 14 |

Total estimado: **≈ 290 aserciones nuevas** (sobre las 349 de E1) + concurrencia + mutación.

### 10.1 Conexiones reales

Cada archivo abre sesiones `psql` **autenticadas por red con contraseña** (como el backend), no `SET ROLE` desde un superusuario.

* **`banco_app` (login real):** 0 `SELECT/INSERT/UPDATE/DELETE/TRUNCATE` sobre las 12 tablas; sin `EXECUTE` sobre `_asentar_grupo` ni las funciones de trigger; no puede `SET ROLE banco_owner/banco_ledger`, `ALTER TABLE … DISABLE TRIGGER`, crear funciones/triggers ni `SET session_replication_role`. Además, con una **función arnés** `tests.app_envio(...)` (propietario `banco_owner`, `SECURITY DEFINER`, existe **solo en `banco_test`**, imita a la futura `hacer_transferencia`) se prueba el camino completo desde la conexión de `banco_app`: mueve saldos solo vía libro, y las variantes con patas falsas o descuadradas son rechazadas.
* **`banco_ledger` — "cuando corresponda":** `banco_ledger` es `NOLOGIN` **a propósito** (nadie debe conectarse con él), así que no admite conexión real. La forma más fiel de probarlo: un rol-sonda `ledger_probe` (LOGIN, `NOINHERIT`, miembro de `banco_ledger`), creado y **eliminado dentro de la propia prueba** (con limpieza previa por si una corrida anterior murió), se conecta de verdad y hace `SET ROLE banco_ledger`. Desde ahí se comprueba: `UPDATE balance` directo → rechazado por el guardia (profundidad 1); `INSERT`/`DELETE` en `transaccion` → permiso denegado; `UPDATE` de columnas no-acumulador → permiso denegado; llamar la función de trigger directamente → error; `SET ROLE banco_owner` → denegado. La sonda es un rol global del clúster mientras dura la prueba; se verifica que desaparece. **Pido tu OK para esta sonda (D-E2-4).**
* **`banco_lector` (login real):** sigue siendo solo lectura; lee `v_integridad_*`; sigue sin `password_hash`.

### 10.2 Concurrencia (procesos `psql` en paralelo **dentro del contenedor**, sin depender de Bash/PowerShell del host)

| Escenario | Esperado |
|---|---|
| Dos sesiones `banco_app` retiran a la vez más de lo que hay | Exactamente una gana; saldo ≥ 0 |
| Transferencias cruzadas A→B ∥ B→A (2×200) | 0 *deadlocks*; saldos finales exactos |
| 8 sesiones, 6 cuentas, transferencias aleatorias (8×500) | 0 errores no esperados; suma total constante; `v_integridad_*` en 0 |
| Doble `BOLSO_INGRESO` simultáneo al mismo bolsillo | Suma exacta |
| Ingreso mientras se lee `v_integridad_saldos` en bucle | Sin falsos positivos |
| Conexión cortada (`pg_terminate_backend`) a mitad de grupo | Sin rastro, sin saldos movidos |
| Inserción directa (sin `_asentar_grupo`) cruzada con una sancionada | Se serializan; sin corrupción |

### 10.3 Verificación en pgAdmin (guía que se entregará)

Consultas para pegar en el Query Tool, todas dentro de `BEGIN … ROLLBACK` (la base no queda sucia): ver triggers y dueños en `pg_trigger`/`pg_proc`; intentar `UPDATE cuenta SET balance=…` y ver el rechazo del guardia; crear dos clientes de prueba, mover dinero con `_asentar_grupo` y ver los saldos; un grupo descuadrado y su error; intentar `DELETE`/`UPDATE` sobre `transaccion`; consultar `v_integridad_*` y `v_integridad_defensas`; y, con la conexión **banco_app**, comprobar que no ve ni puede llamar nada. Con capturas en la carpeta de evidencias, como en E1.

---

## 11. Riesgos y límites

1. **Superusuario:** puede desactivar triggers o usar `session_replication_role = replica`. Se mitiga con roles sin superusuario, auditoría de DDL y `v_integridad_defensas`; no se puede eliminar.
2. **Errores diferidos:** una inserción directa mal armada falla *en el COMMIT* (L6). El camino sancionado (`_asentar_grupo`) los detecta antes y los entrega como `P0001`.
3. **Borrado de cuentas:** destruye saldos y deja la pata del otro cliente "sola"; queda auditado y clasificado, pero la conservación global (I5g) hay que leerla junto con `CUENTA_BORRADA`.
4. **`fecha` sin validar:** hasta E3 el libro acepta cualquier `fecha` de negocio; la hora real queda en `registrado_en`.
5. **Mensajes:** solo `Saldo insuficiente` es del contrato; el resto de errores del libro son internos (`Libro mayor: …`). La lista final para el usuario sigue siendo D13 del equipo.
6. **Rendimiento:** cada pata cuesta 2–3 consultas indexadas extra; a la escala del proyecto es despreciable y se mide en `18_libro_aislamiento`.
7. **Ruido de auditoría:** reaplicar scripts registra eventos DDL sobre tablas protegidas; se documenta y las pruebas lo descuentan.
8. **Pruebas de E1 adaptadas** (sección 9): es la única modificación de entregables aprobados, además de la decisión D-E2-2.

---

## 12. Decisiones que necesito de ti

| ID | Decisión | Recomendación |
|---|---|---|
| **D-E2-1** | ¿Las plantillas de `CREDITO_CUOTA/ABONO/MORA` esperan a D7 (E9)? | **Sí, esperar.** Mientras, solo G1–G5 + matriz por pata. Evita adelantar la decisión financiera |
| **D-E2-2** | ¿Añadir `registrado_en` y `tx_id` a `transaccion` (nuevo `ALTER TABLE`, sin tocar `03_schema.sql`)? | **Sí.** Trazabilidad real y sellado de grupos sin trucos de `xmin` |
| **D-E2-3** | El dueño pierde `UPDATE` de tabla en las 4 tablas de acumuladores y `UPDATE`/`TRUNCATE` en `transaccion`; conserva `UPDATE` solo de columnas no-acumulador (L3) | **Sí.** Un error en una función de negocio ya no puede tocar saldos ni por accidente |
| **D-E2-4** | Rol-sonda `ledger_probe` temporal, solo en pruebas, para tener una conexión real que pueda asumir `banco_ledger` | **Sí.** Es la única forma de probar `banco_ledger` con conexión real sin volverlo `LOGIN` |
| **D-E2-5** | `credito` nace con `capital_pendiente = 0` y el desembolso lo sube (impacto en E8) | **Sí.** Coherente con D2 y con "ningún contenedor nace con saldo" |
| **D-E2-6** | Adaptar las pruebas de E1 afectadas con `session_replication_role = replica` (solo `banco_test`) | **Sí.** Conserva las 349 aserciones y su significado |

## 13. Plan de ejecución (cuando apruebes)

E2.1 estructura y permisos → E2.2 guardias y trigger de aplicar → E2.3 cuadre, plantillas y CDT → E2.4 inmutabilidad, auditoría y event trigger → E2.5 vistas de integridad → E2.6 pruebas SQL → E2.7 conexiones reales y concurrencia → E2.8 mutación, documentación, evidencias y guía de pgAdmin. Una sola entrega al final, con ejecución limpia de todo desde cero (`reset` + 3 `apply`), 349 + nuevas aserciones en verde y **parada para tu revisión**, sin commits y sin empezar E3.
