# Banco Digital Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un banco digital funcional donde toda la lógica de negocio vive en funciones/triggers/vistas de PostgreSQL, con backend Express delgado, front React y despliegue con `docker compose up`.

**Architecture:** El front (nginx, proxy `/api`) habla solo con el backend; el backend ejecuta `SELECT funcion(...)` por un único pool `pg` y traduce errores (`P0001` → 400 con el mensaje, cualquier otro error de conexión → 503 `{error:"sin_conexion"}`). La BD es dueña de reglas, saldos y auditoría; el rol de la app NO tiene permisos sobre tablas, solo `EXECUTE` sobre funciones y `SELECT` sobre vistas.

**Tech Stack:** PostgreSQL 16, Node 20 + Express + TypeScript (vitest + supertest), React + Vite + TypeScript (vitest), Docker Compose, pgAdmin 4, Resend.

**Spec:** `docs/specs/2026-11-06-banco-de-diseño.pdf` (secciones citadas como §N). Este plan incorpora los arreglos de la revisión del 2026-11-10 (marcados **[FIX n]**, ver tabla abajo).

## Global Constraints

- PostgreSQL propio en Docker + pgAdmin 4; **no Supabase** (§3).
- Ids `UUID` con `gen_random_uuid()`; montos `NUMERIC(18,2)` en COP; fechas con zona (§5).
- Cero lógica de negocio en backend/front; cero SQL con lógica en el backend (§4.1).
- Cualquier error de conexión/timeout → HTTP 503 `{error:"sin_conexion"}`; errores de negocio = `RAISE EXCEPTION ... USING ERRCODE='P0001'` → HTTP 400 con el mensaje (§15.8).
- Front: un solo catch en el cliente fetch que muestra "Error de conexión, estamos trabajando para solucionarlo" solo ante 503 (§10).
- Sesión: cookie `httpOnly`, `sameSite=lax`, `secure` en producción, JWT; rol/estado se leen de la BD en cada petición (§7.2, §9).
- Contraseñas: bcrypt (10–12 rondas), mínimo 8 caracteres, 1 mayúscula, 1 número (§9).
- Mensaje exacto de bloqueo: `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla` (§7.2).
- Reloj: `hoy_banco()` reemplaza a `NOW()` para toda fecha de negocio; solo avanza (§6).
- Tasa diaria = anual/365; i mensual = anual/12 (§15.2). Bolsillos 12% anual. Bono de referido $50.000. 5 `INGRESO_SIMULADO` de $10.000–$1.000.000 al registrar (§7.1).
- Tabla de créditos (§7.6): Libre inversión ≤24 m, tope $30M fijo; Vehículo $50M–$200M, ≤120 m; Educación $1M–$100M, ≤240 m; Inmuebles ≤360 m, tope min(100× balance total, $2.000M), regla `edad_actual + plazo_años ≤ 70`.
- Un solo pool `pg`; `docker compose up -d` desde cero levanta todo (4 servicios, §11).
- Git: `main` protegida, una rama por pieza (`feat/db-core`, `feat/backend-auth`, `feat/docker-compose`, `feat/front-*`).

## Arreglos incorporados

| # | Arreglo | Dónde se implementa |
|---|---|---|
| FIX 1 | Saldos protegidos: rol `banco_app` sin permisos sobre tablas + trigger que bloquea `UPDATE` directo de `balance` fuera de funciones | Task 1, 2 |
| FIX 2 | Fecha vs hora: `hoy_banco()` (date) + `ahora_banco()` (timestamptz = hoy del banco + hora real) | Task 2 |
| FIX 3 | Borrado en cascada documentado como decisión consciente; contraparte guardada como texto | Task 8 |
| FIX 4 | Tope Inmuebles y "un vivo por producto" probados con casos límite | Task 7 |
| FIX 5 | Bono de referido en UNA función; el backend pasa el flag `p_verificacion_activa` | Task 3 |
| FIX 6 | Contrato de login: BD entrega hash, backend compara bcrypt, BD valida estado | Task 3, 10 |
| FIX 7 | Endpoints faltantes: verificación de correo y reenvío (recuperación de contraseña queda fuera, ver Review Focus) | Task 3, 11 |
| FIX 8 | Pestaña Control con columnas sensibles enmascaradas y ping con guarda anti-solapamiento | Task 8, 14 |
| FIX 9 | Pool `pg` se recupera tras `stop db`/`start db` (test automatizado) | Task 10 |
| FIX 10 | `avanzar_hasta` resume por bolsillo/CDT en UN INSERT por llamada (no uno por día) | Task 6 |
| FIX 11 | Tests SQL automáticos de cada función (runner `psql`, sin dependencias extra) | Task 0 + cada Task de BD |
| FIX 12 | Reparto de frentes definido (Task 16) | Task 16 |

## Review Focus

Entradas/condiciones que el spec implica pero ninguna tarea cubre por defecto; cada una tiene su test en la tarea indicada:

1. **Doble clic / dos peticiones simultáneas de transferencia** con saldo justo: la segunda debe fallar con "saldo insuficiente", nunca dejar saldo negativo (Task 4).
2. **Transferirse a sí mismo o a una cuenta inexistente / monto 0 o negativo / monto con >2 decimales**: error 400 claro, sin movimientos (Task 4).
3. **Adelantar el reloj años de golpe** (p. ej. 30 años con crédito de 360 cuotas): `avanzar_hasta` termina en < 5 s y los saldos coinciden con el cálculo (Task 6, 7).
4. **Usuario bloqueado con sesión ya abierta**: la siguiente petición responde el mensaje de bloqueo, no datos (Task 3, 10).
5. **Recuperación de contraseña**: el spec no la define; queda explícitamente FUERA de alcance y el login devuelve "Credenciales inválidas" genérico; se anota en el spec (Task 16).

---

### Task 0: Esqueleto Docker + runner de tests SQL (rama `feat/docker-compose`)

**Files:**
- Create: `docker-compose.yml`, `.env.example`, `db/init/.gitkeep`, `db/tests/run.sh`, `db/tests/helpers.sql`, `db/tests/00_smoke.test.sql`

**Interfaces:**
- Produces: servicio `db` (postgres:16-alpine, volumen `pgdata`, healthcheck `pg_isready`), servicio `pgadmin` (puerto 5050, servidor preconfigurado a `db:5432`); `db/tests/run.sh` ejecuta cada `*.test.sql` en una BD temporal recreada desde `db/init/*.sql` y sale ≠0 si alguno falla; `helpers.sql` define `assert_eq(label text, actual anyelement, expected anyelement)` y `assert_raises(label text, sql text, expected_msg text)` (ambos hacen `RAISE EXCEPTION` si fallan).

- [ ] **Step 1: Write the failing test** `db/tests/00_smoke.test.sql`: `SELECT assert_eq('smoke', 1, 1);`
- [ ] **Step 2: Run** `bash db/tests/run.sh` → Expected: FAIL (runner/compose no existen).
- [ ] **Step 3: Implement** `docker-compose.yml` (servicios `db`, `pgadmin`; `backend` y `front` se añaden en Tasks 10 y 12), `run.sh` (`docker compose exec -T db psql -v ON_ERROR_STOP=1`, crea BD `banco_test`, aplica `db/init/*.sql` en orden, luego tests) y `helpers.sql`.
- [ ] **Step 4: Run** `bash db/tests/run.sh` → Expected: `1 passed, 0 failed`.
- [ ] **Step 5: Commit** `git commit -m "chore: docker db + sql test runner"`

### Task 1: Esquema, roles y permisos (rama `feat/db-core`) — FIX 1

**Files:**
- Create: `db/init/00_roles.sql`, `db/init/01_schema.sql`, `db/tests/01_schema.test.sql`

**Interfaces:**
- Produces: las 11 tablas de §5 (`usuario, cuenta, bolsillo, cdt, cdt_definicion, credito_producto, credito, cuota, transaccion, reloj, parametro`) con todos los UNIQUE/CHECK/FK de §5; enum `tipo_transaccion` con los 17 tipos de §5; rol `banco_app` (LOGIN, sin permisos sobre tablas, solo `USAGE` en schema).

- [ ] **Step 1: Write failing tests** en `01_schema.test.sql`: (a) insertar usuario con cédula duplicada → `unique_violation`; (b) `monto <= 0` en `transaccion` → `check_violation`; (c) `SET ROLE banco_app; SELECT * FROM cuenta;` → `insufficient_privilege`; (d) `UPDATE cuenta SET balance=1` como `banco_app` → `insufficient_privilege`.
- [ ] **Step 2: Run** `bash db/tests/run.sh` → FAIL.
- [ ] **Step 3: Implement** `00_roles.sql` (rol `banco_app`, contraseña desde variable de entorno de init) y `01_schema.sql` (tablas §5; `cdt.tasa_anual/monto` copiados al crear; `transaccion` guarda `contraparte_nombre text`, `contraparte_cuenta text` como texto sin FK — FIX 3). Cada función futura será `SECURITY DEFINER` con `SET search_path = public` y `GRANT EXECUTE ... TO banco_app`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): schema, roles y permisos"`

### Task 2: Reloj, triggers de bitácora y guarda de saldos — FIX 1, 2

**Files:**
- Create: `db/init/02_reloj.sql`, `db/init/03_triggers.sql`, `db/tests/02_reloj.test.sql`

**Interfaces:**
- Produces: `hoy_banco() RETURNS date` (real → `current_date`; manual → `reloj.fecha_sistema`); `ahora_banco() RETURNS timestamptz` (= `hoy_banco()` + hora real del día); trigger en `reloj` que rechaza retroceder `fecha_sistema` con `P0001 'El reloj no puede retroceder'`; trigger `BEFORE UPDATE OF balance` en `cuenta` y `bolsillo` que falla salvo que la sesión tenga `SET LOCAL banco.interno='on'` (solo lo ponen las funciones del banco); trigger `AFTER INSERT` en `transaccion` que valida `saldo_posterior = saldo_previo ± monto` según tipo (bitácora automática, §5.9).

- [ ] **Step 1: Write failing tests:** `assert_eq('hoy real', hoy_banco(), current_date)`; con reloj manual 2027-01-10, `hoy_banco()` = esa fecha y `ahora_banco()::date` = esa fecha; `assert_raises('retroceso', 'UPDATE reloj SET usar_fecha_real=false, fecha_sistema=''2026-01-01''', 'El reloj no puede retroceder')`; `assert_raises('balance directo', 'UPDATE cuenta SET balance=balance+1', 'Los saldos solo cambian mediante funciones del banco')`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** funciones y triggers. Función auxiliar interna `_modo_interno()` que activa `banco.interno` con `set_config(..., true)`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): reloj, triggers y guarda de saldos"`

### Task 3: Registro, credenciales, verificación y referidos — FIX 5, 6, 7

**Files:**
- Create: `db/init/04_auth.sql`, `db/tests/03_auth.test.sql`

**Interfaces:**
- Produces:
  - `registrar_usuario(p_nombres text, p_apellidos text, p_cedula text, p_correo text, p_telefono text, p_fecha_nacimiento date, p_password_hash text, p_acepta_politica boolean, p_codigo_referido uuid, p_verificacion_activa boolean) RETURNS TABLE(usuario_id uuid, username text)`
  - `verificar_correo(p_usuario_id uuid) RETURNS void` (marca `correoverificado` y llama a `_pagar_bono_referido`)
  - `_pagar_bono_referido(p_usuario_id uuid) RETURNS void` (**única** implementación del bono $50.000 `BONO_REFERIDO`; idempotente)
  - `obtener_credenciales(p_username text) RETURNS TABLE(usuario_id uuid, password_hash text, rol text, estado text)` (nunca lanza por usuario inexistente: devuelve 0 filas)
  - `validar_sesion(p_usuario_id uuid) RETURNS TABLE(rol text, estado text)` — lanza `P0001` con el mensaje exacto de bloqueo si `estado='BLOQUEADO'`.
- Contrato del login (FIX 6): el backend llama `obtener_credenciales`, compara bcrypt en Node, luego `validar_sesion`; la BD jamás ve la contraseña en claro.

- [ ] **Step 1: Write failing tests:** (a) username = primera letra nombre + primer apellido + 3–4 dígitos, único (`jperez483` patrón `^[a-z]+[0-9]{3,4}$`), `numero_cuenta` 10 dígitos, 5 transacciones `INGRESO_SIMULADO` con montos en [10000,1000000] y fechas < `ahora_banco()`, y `cuenta.balance` = suma; (b) sin aceptar política → `assert_raises(... 'Debe aceptar la política de datos')`; (c) con `codigo_referido` y `p_verificacion_activa=false` el referidor recibe +50000 al registrar; con `true` no hasta `verificar_correo`; llamar `verificar_correo` dos veces no paga dos veces; (d) `validar_sesion` de bloqueado lanza el mensaje exacto; (e) `obtener_credenciales('noexiste')` devuelve 0 filas.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** las cinco funciones; todo movimiento de saldo vía `_modo_interno()` + INSERT en `transaccion`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): registro, credenciales, verificacion y referidos"`

### Task 4: Transferencias entre cuentas

**Files:**
- Create: `db/init/05_transferencias.sql`, `db/tests/04_transferencias.test.sql`

**Interfaces:**
- Consumes: `hoy_banco`, `ahora_banco`, `_modo_interno` (Task 2).
- Produces:
  - `nombre_destinatario(p_numero_cuenta text) RETURNS text` (nombre completo o `P0001 'Cuenta no encontrada'`)
  - `hacer_transferencia(p_usuario_id uuid, p_numero_destino text, p_monto numeric, p_nota text, p_bolsillo_origen uuid DEFAULT NULL) RETURNS uuid` (id de la transacción `ENVIO`); inserta `ENVIO` en origen y `RECIBO` en destino en la misma transacción; `SELECT ... FOR UPDATE` en ambas cuentas ordenadas por id (evita deadlock).

- [ ] **Step 1: Write failing tests:** transferencia válida deja saldos correctos y 2 filas con `contraparte` en cada lado; saldo insuficiente → "Saldo insuficiente"; a sí mismo → "No puedes enviarte dinero a ti mismo"; cuenta inexistente → "Cuenta no encontrada"; monto 0, negativo o con 3 decimales → "Monto inválido"; origen bolsillo descuenta del bolsillo; **concurrencia** (Review Focus 1): script con dos sesiones `psql` simultáneas con saldo 100 y dos envíos de 80 → exactamente una falla y saldo final 20.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** ambas funciones.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): transferencias atomicas"`

### Task 5: Bolsillos

**Files:**
- Create: `db/init/06_bolsillos.sql`, `db/tests/05_bolsillos.test.sql`

**Interfaces:**
- Produces: `crear_bolsillo(p_usuario_id uuid, p_nombre text) RETURNS uuid`; `mover_a_bolsillo(p_usuario_id uuid, p_bolsillo_id uuid, p_monto numeric) RETURNS void` (`BOLSO_INGRESO`); `retirar_de_bolsillo(p_usuario_id uuid, p_bolsillo_id uuid, p_monto numeric) RETURNS void` (`BOLSO_RETIRO`); `mover_entre_bolsillos(p_usuario_id uuid, p_origen uuid, p_destino uuid, p_monto numeric) RETURNS void` (`BOLSO_MOVIMIENTO`). Todas validan propiedad (`P0001 'Recurso no encontrado'` si el bolsillo no es del usuario).

- [ ] **Step 1: Write failing tests:** mover 100 a bolsillo baja cuenta/sube bolsillo y escribe `BOLSO_INGRESO`; retirar más que el saldo falla; bolsillo ajeno falla con 'Recurso no encontrado'; `ultimo_cobro` se inicializa a `hoy_banco()` al crear.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): bolsillos"`

### Task 6: Motor de cobro lazy + CDTs — FIX 10

**Files:**
- Create: `db/init/07_lazy.sql`, `db/init/08_cdt.sql`, `db/tests/06_lazy_cdt.test.sql`

**Interfaces:**
- Produces:
  - `avanzar_hasta(p_usuario_id uuid) RETURNS void` — idempotente; para cada bolsillo calcula `Σ días × saldo × 0.12/365` desde `ultimo_cobro+1` hasta `hoy_banco()` y escribe **un** `INTERES_BOLSO` por bolsillo por llamada (nota "N días"); para cada CDT suma a `generado_acumulado` y al llegar `fecha_fin` genera `CDT_VENCIMIENTO` (principal + generado) y pone `estado='CERRADO'`; para créditos delega en `_cobrar_creditos(p_usuario_id)` (Task 7). Se invoca al inicio de TODA función de lectura/escritura del cliente y de las vistas por RPC.
  - `crear_cdt(p_usuario_id uuid, p_definicion_id uuid, p_monto numeric) RETURNS uuid` (copia tasa/plazo/monto; `CDT_CREACION`; `fecha_fin = hoy_banco() + plazo_dias`); no existe función de retiro anticipado.
  - `simular_cdt(p_definicion_id uuid, p_monto numeric) RETURNS TABLE(generado_mes numeric, generado_dia numeric, generado_vencimiento numeric)`.

- [ ] **Step 1: Write failing tests:** bolsillo con 1.000.000 y reloj +30 días → interés = `ROUND(1000000*0.12/365*30, 2)` en una sola fila `INTERES_BOLSO`; llamar `avanzar_hasta` dos veces el mismo día no duplica; CDT 6 meses con reloj +200 días → `estado='CERRADO'`, `CDT_VENCIMIENTO = monto + generado`; tasa de definición editada después no cambia CDTs vivos; **rendimiento** (Review Focus 3): reloj +10950 días con 5 bolsillos termina en < 5 s.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** con aritmética por rango (no bucle por día). Redondeo: `ROUND(x, 2)` half-up, una vez por fila escrita.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): cobro lazy y cdts"`

### Task 7: Créditos — FIX 4

**Files:**
- Create: `db/init/09_creditos.sql`, `db/init/12_seed_productos.sql`, `db/tests/07_creditos.test.sql`

**Interfaces:**
- Consumes: `avanzar_hasta` (Task 6) que llama `_cobrar_creditos`.
- Produces:
  - `balance_total(p_usuario_id uuid) RETURNS numeric` = balance + Σ bolsillos + Σ CDT activos − Σ `capital_pendiente` de créditos activos.
  - `productos_disponibles(p_usuario_id uuid) RETURNS TABLE(producto_id uuid, nombre text, tasa_anual numeric, monto_min numeric, monto_max numeric, plazo_max_meses int)` (aplica regla de edad y tope en la lista).
  - `simular_credito(p_producto_id uuid, p_monto numeric, p_plazo_meses int) RETURNS TABLE(cuota numeric, total_pagar numeric, intereses_totales numeric)`; cuota francesa `P·i·(1+i)^n / ((1+i)^n − 1)`, `i = tasa_anual/12`; redondeo a 2 decimales y **la última cuota absorbe la diferencia** para que Σ capital = monto.
  - `solicitar_credito(p_usuario_id uuid, p_producto_id uuid, p_monto numeric, p_plazo_meses int) RETURNS uuid` (desembolso instantáneo `CREDITO_DESEMBOLSO`, genera todas las `cuota`).
  - `pagar_cuota(p_usuario_id uuid, p_credito_id uuid) RETURNS void` (`CREDITO_CUOTA`); `abonar_credito(p_usuario_id uuid, p_credito_id uuid, p_monto numeric) RETURNS void` (primero intereses del mes, resto baja capital, recalcula cuotas restantes con mismo plazo y tasa; `CREDITO_ABONO`); `activar_descuento_automatico(p_usuario_id uuid, p_credito_id uuid, p_activo boolean) RETURNS void`; `_cobrar_creditos(p_usuario_id uuid) RETURNS void` (descuento automático o marca vencida + `CREDITO_MORA` acumulada con `parametro.tasa_mora_anual` sobre el valor de la cuota, resumida en un INSERT por crédito por llamada).
- Seed: 4 filas de `credito_producto` con los valores de §7.6 y tasas iniciales editables.

- [ ] **Step 1: Write failing tests:** Σ capital de las cuotas = monto exacto (con 360 cuotas); cuota fija coincide con fórmula para P=10.000.000, i=0.015, n=12; segundo Vehículo vivo → "Ya tienes un crédito vigente de este producto" pero Educación sí se permite; Libre inversión 30.000.001 → "Monto fuera de rango"; Inmuebles con 43 años y 30 años de plazo → "Plazo excede el límite de edad", la lista `productos_disponibles` trunca a 27 años; **autoneutralización** (FIX 4): tomar crédito no aumenta `balance_total` (±0.01) y pedir Inmuebles dos veces seguidas respeta el tope calculado con `balance_total`; cuota vencida sin descuento → crece `CREDITO_MORA` y estado `vencida`; con descuento y saldo → se paga sola; abono reduce la cuota; reloj +30 años en crédito de 360 cuotas termina en < 5 s.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): creditos"`

### Task 8: Funciones admin y visor Control — FIX 3, 8

**Files:**
- Create: `db/init/10_admin.sql`, `db/tests/08_admin.test.sql`

**Interfaces:**
- Produces (todas reciben `p_admin_id uuid` y fallan con `P0001 'Acceso denegado'` si `rol <> 'ADMIN'` leído de la BD):
  - `admin_listar_usuarios(p_admin_id uuid, p_busqueda text) RETURNS TABLE(...)` (nombre/cédula/correo/número de cuenta); `admin_detalle_usuario(p_admin_id uuid, p_usuario_id uuid) RETURNS jsonb` (balance desglosado).
  - `admin_bloquear(p_admin_id uuid, p_usuario_id uuid)`, `admin_desbloquear(...)`, `admin_borrar_usuario(p_admin_id uuid, p_usuario_id uuid)` — borra en cascada; antes de borrar, reescribe `contraparte_nombre/contraparte_cuenta` en transacciones de terceros (FIX 3, documentado en spec §15.5/§15.11).
  - `admin_ajustar_balance(p_admin_id uuid, p_usuario_id uuid, p_monto numeric, p_nota text) RETURNS void` (`AJUSTE_ADMIN`).
  - `admin_set_reloj(p_admin_id uuid, p_usar_fecha_real boolean, p_fecha date) RETURNS void`.
  - `admin_set_tasa_cdt(p_admin_id uuid, p_definicion_id uuid, p_tasa numeric)`, `admin_set_tasa_credito(... p_producto_id ...)`, `admin_set_tasa_mora(p_admin_id uuid, p_tasa numeric)`.
  - `admin_esquema(p_admin_id uuid) RETURNS jsonb` (tablas, columnas, claves y FKs desde `information_schema`).
  - `admin_tabla(p_admin_id uuid, p_tabla text, p_pagina int) RETURNS jsonb` — whitelist de las 11 tablas; **columna `password_hash` devuelta como `'••••'`** (FIX 8); 50 filas por página.

- [ ] **Step 1: Write failing tests:** no-admin recibe 'Acceso denegado' en cada función; `admin_tabla(..., 'usuario', 1)` nunca contiene el hash real; tabla fuera de whitelist → 'Tabla no permitida'; borrar usuario deja el historial del tercero con nombre+cuenta en texto y sin FKs huérfanas; ajustar balance escribe `AJUSTE_ADMIN` con la nota.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): funciones admin y visor control"`

### Task 9: Vistas para el front

**Files:**
- Create: `db/init/11_vistas.sql`, `db/tests/09_vistas.test.sql`

**Interfaces:**
- Produces: funciones-vista parametrizadas (corren `avanzar_hasta` primero): `vista_dashboard(p_usuario_id uuid) RETURNS jsonb` (saludo, balance total, últimas transacciones, resumen CDT y créditos); `vista_historial(p_usuario_id uuid, p_limite int DEFAULT 50) RETURNS TABLE(...)`; `vista_cdts(p_usuario_id uuid) RETURNS TABLE(...)` (monto, generado hasta hoy, tiempo restante, fecha cierre); `vista_creditos(p_usuario_id uuid) RETURNS TABLE(...)` (cuotas pagadas/faltantes, mora acumulada, interés corriendo); `vista_perfil(p_usuario_id uuid) RETURNS jsonb` (número de cuenta, username, `codigo_referido`).

- [ ] **Step 1: Write failing tests:** el dashboard de un usuario recién registrado muestra balance = Σ de las 5 transacciones simuladas; envíos tienen signo negativo y recibos positivo; `vista_historial` respeta `p_limite`; llamar la vista con reloj +30 días incluye el interés ya cobrado.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(db): vistas"`

### Task 10: Backend — esqueleto, sesión y regla 503 (rama `feat/backend-auth`) — FIX 6, 9

**Files:**
- Create: `backend/package.json`, `backend/tsconfig.json`, `backend/Dockerfile.backend`, `backend/src/db.ts`, `backend/src/errors.ts`, `backend/src/session.ts`, `backend/src/routes/auth.ts`, `backend/src/app.ts`, `backend/src/server.ts`, `backend/test/errors.test.ts`, `backend/test/auth.test.ts`, `backend/test/outage.test.ts`
- Modify: `docker-compose.yml` (servicio `backend`, `depends_on: db: condition: service_healthy`)

**Interfaces:**
- Produces:
  - `db.ts`: `pool: Pool` (un único `pg.Pool`, `connectionTimeoutMillis: 2000`, handler `pool.on('error')` que NO relanza) y `call<T>(fn: string, args: unknown[]): Promise<T[]>` que ejecuta `SELECT * FROM fn($1,...)` (nombre de función validado contra whitelist).
  - `errors.ts`: `errorMiddleware(err, req, res, next)`: `err.code==='P0001'` → 400 `{error: err.message}`; **cualquier otro** → 503 `{error:'sin_conexion'}`.
  - `session.ts`: `requireSession` (valida JWT de cookie + llama `validar_sesion` en cada petición → bloqueo inmediato) y `requireAdmin`.
  - `routes/auth.ts`: `POST /api/auth/registro` (bcrypt del password, pasa `p_verificacion_activa = process.env.RESEND_ENABLED==='true'`; envía correo por Resend si activo), `POST /api/auth/verificar` (`{token}` → `verificar_correo`), `POST /api/auth/reenviar`, `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/yo`. Rate limit de login por IP y por usuario (5 intentos / 15 min).

- [ ] **Step 1: Write failing tests:** (a) error con `code='P0001'` → 400 y mensaje; `ECONNREFUSED`/timeout → 503 `{error:"sin_conexion"}`; (b) login correcto pone cookie `httpOnly; SameSite=Lax`; contraseña incorrecta o usuario inexistente → 400 "Credenciales inválidas" idéntico; usuario bloqueado → 400 con el mensaje exacto de bloqueo; sesión abierta + bloqueo posterior → siguiente `GET /api/yo` devuelve el mensaje de bloqueo (Review Focus 4); el 6.º intento → 429; (c) **outage** (FIX 9): test de integración que hace `docker compose stop db`, comprueba 503 sin que el proceso caiga, `docker compose start db` y comprueba que la misma petición vuelve a 200 sin reiniciar el backend.
- [ ] **Step 2: Run** `cd backend && npx vitest run` → FAIL.
- [ ] **Step 3: Implement** lo anterior; el backend no contiene intereses, saldos ni SQL de negocio.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(backend): sesion, auth y regla 503"`

### Task 11: Backend — endpoints de cliente y admin

**Files:**
- Create: `backend/src/routes/cliente.ts`, `backend/src/routes/admin.ts`, `backend/test/cliente.test.ts`, `backend/test/admin.test.ts`

**Interfaces:**
- Consumes: `call`, `requireSession`, `requireAdmin` (Task 10).
- Produces: los endpoints de §13 sin cambios, más `GET /api/destinatario/:numero` (→ `nombre_destinatario`), `POST /api/creditos/:id/descuento` y `GET/PUT /api/admin/reloj`. Cada handler es **una** llamada a una función/vista de la BD con el `usuario_id` de la sesión (nunca del body). Ruta ajena → 403 vía `P0001 'Recurso no encontrado'` mapeado a 403 en un único helper `mapNegocio` (§9). `GET /api/admin/tabla/:nombre` y `/esquema` usan `admin_tabla`/`admin_esquema`.

- [ ] **Step 1: Write failing tests** (supertest con BD real de test): cada endpoint cliente sin cookie → 401; con usuario A pidiendo bolsillo/crédito/CDT de B → 403 aunque cambie el UUID en la URL; cliente en `/api/admin/*` → 403; envío válido → 200 y el destinatario ve el RECIBO; monto negativo → 400 con mensaje de la BD (no del backend).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(backend): endpoints cliente y admin"`

### Task 12: Front — esqueleto, cliente fetch con catch único y pantallas públicas (rama `feat/front-shell`)

**Files:**
- Create: `front/package.json`, `front/vite.config.ts`, `front/Dockerfile.front`, `front/nginx.conf`, `front/src/api/client.ts`, `front/src/components/ErrorBanner.tsx`, `front/src/pages/Inicio.tsx`, `front/src/pages/Registro.tsx`, `front/src/pages/Login.tsx`, `front/src/App.tsx`, `front/src/api/client.test.ts`
- Modify: `docker-compose.yml` (servicio `front`, nginx con proxy `/api` → `backend`)

**Interfaces:**
- Produces: `api<T>(path: string, init?: RequestInit): Promise<T>` — único punto de fetch (`credentials:'include'`); ante 503 emite el evento global `conexion-perdida` (muestra `ErrorBanner` "Error de conexión, estamos trabajando para solucionarlo") y rechaza con `ConexionError`; ante 400 rechaza con `NegocioError(message)`; ante otros → `Error`. El token nunca se guarda en `localStorage`.

- [ ] **Step 1: Write failing tests** (`client.test.ts` con fetch mockeado): 503 → rechaza `ConexionError` y dispara `conexion-perdida`; 400 → `NegocioError` con el mensaje del servidor; no se usa `localStorage`; `Registro` guarda `?ref=<uuid>` y lo envía; `Login` muestra tal cual el mensaje de bloqueo.
- [ ] **Step 2: Run** `cd front && npx vitest run` → FAIL.
- [ ] **Step 3: Implement.** Inicio muestra textos de marketing fijos y los 4 productos desde `GET /api/creditos/productos` con fallback estático (§12).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(front): shell, cliente fetch y pantallas publicas"`

### Task 13: Front — panel de cliente (rama `feat/front-cliente`)

**Files:**
- Create: `front/src/pages/cliente/{Dashboard,Balance,Creditos,Cdts,Perfil}.tsx`, `front/src/components/{EnvioForm,TransaccionList,Simulador}.tsx`, `front/src/pages/cliente/cliente.test.tsx`

**Interfaces:**
- Consumes: `api<T>` (Task 12) y los endpoints de §13.
- Produces: pestañas Inicio/Balance/Créditos/CDTs/Perfil; `EnvioForm` pide número, llama `GET /api/destinatario/:numero` y muestra "¿Envías a …?" antes de confirmar; envíos en rojo con `-`, recibos en verde con `+`; el botón de enviar se deshabilita mientras la petición está en vuelo (anti doble clic, Review Focus 1).

- [ ] **Step 1: Write failing tests:** el nombre del destinatario aparece antes de confirmar; doble clic produce una sola llamada a `POST /api/envios`; con 503 el panel mantiene menús y muestra el banner sin datos; simulador de crédito muestra cuota, total e intereses devueltos por el backend (el front no calcula).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(front): panel de cliente"`

### Task 14: Front — panel admin y pestaña Control (rama `feat/front-admin`) — FIX 8

**Files:**
- Create: `front/src/pages/admin/{Usuarios,Operaciones,Reloj,Tasas,Control}.tsx`, `front/src/components/Grafo.tsx`, `front/src/pages/admin/admin.test.tsx`

**Interfaces:**
- Consumes: `GET /api/admin/esquema`, `/api/admin/tabla/:nombre`.
- Produces: `Control` dibuja el grafo de tablas/FKs (layout automático desde el esquema), filtro por tabla, filas paginadas; hace **ping periódico a `/api/admin/esquema` cada 5 s con guarda** (no inicia otro ping si el anterior sigue en vuelo; se detiene si la pestaña no está visible) y muestra DESCONECTADO en rojo al recibir 503.

- [ ] **Step 1: Write failing tests:** con timers falsos solo hay 1 petición en vuelo aunque pasen 20 s con respuesta lenta; ante 503 aparece DESCONECTADO; la tabla `usuario` nunca renderiza un hash; el selector de reloj no permite fechas anteriores a la actual.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(front): panel admin y control"`

### Task 15: Semilla, apagón y recorrido completo (QA)

**Files:**
- Create: `db/seed/seed.sh` (llama funciones reales, nunca SQL crudo), `docs/runbook-demo.md`, `e2e/recorrido.test.ts`
- Modify: `docker-compose.yml` (imágenes precargadas documentadas en el runbook)

**Interfaces:**
- Consumes: todas las funciones de las Tasks 3–9 vía el backend.
- Produces: `seed.sh` crea admin, 3 usuarios con bolsillos, CDTs y créditos "corridos" avanzando el reloj; `runbook-demo.md` con pasos de `docker compose up -d`, `stop db`, qué debe verse, `start db`, y cómo apagar el flag de Resend.

- [ ] **Step 1: Write failing test** `e2e/recorrido.test.ts`: registro → login → envío → CDT → crédito → admin adelanta reloj 30 días → intereses visibles; luego `docker compose stop db` → toda ruta de datos responde 503 y la pantalla muestra el banner; `start db` → vuelve sin pasos extra.
- [ ] **Step 2: Run** `npx vitest run e2e` en una máquina limpia (`docker compose down -v && docker compose up -d`) → FAIL.
- [ ] **Step 3: Implement** semilla y runbook; ensayar el apagón en local.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "test: recorrido completo, semilla y runbook"`

### Task 16: Reparto de frentes y actualización del spec — FIX 12

**Files:**
- Modify: `docs/specs/2026-11-06-banco-de-diseño.pdf` (fuente) → agregar nota fechada con los arreglos FIX 1–12 y mover recuperación de contraseña a no-metas.
- Create: `docs/reparto.md`

**Interfaces:**
- Produces: tabla frente → persona, **ya definida por el equipo (2026-11-10)**: **Front (Tasks 12–14) = Daniel García**, **BD (Tasks 1–9) = Daniel Monterroza**, **Docker (Task 0) + QA/Seed (Task 15) = Jose Samur**, **Backend (Tasks 10–11) = Juan Marin**. Daniel García revisa todos los merges. Nota de riesgo: la BD es el cuello de botella y recae en una sola persona; las firmas de funciones (Tasks 3–9) deben fijarse primero para que los demás avancen.

- [ ] **Step 1: Escribir** `docs/reparto.md` con la propuesta y pedir confirmación al equipo.
- [ ] **Step 2: Anotar** en el spec la fecha y los cambios (FIX 1–12; recuperación de contraseña fuera).
- [ ] **Step 3: Commit** `git commit -m "docs: reparto y arreglos del spec"`

## Orden y dependencias

Task 0 → Task 1 → Task 2 → Tasks 3–5 (secuenciales, comparten reloj) → Task 6 → Task 7 → Tasks 8–9. **En paralelo desde que existan las firmas** (§16.1): Task 10–11 (backend contra firmas) y Tasks 12–14 (front con datos de mentira). Task 15–16 al final.
