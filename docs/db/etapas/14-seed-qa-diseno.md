# Etapa 14 — Seed y QA (datos de demostración, respaldo/restauración, runbook y aceptación) · DISEÑO TÉCNICO v1 (compacto, para aprobación)

**Estado (2026-11-25): DISEÑO v1 APROBADO (con 3 condiciones: protección del respaldo, limpieza de `seed`, reproducibilidad funcional) e IMPLEMENTADO: ver `14-seed-qa.md`, pendiente de auditoría.** E13 aprobada y cerrada. Sin commits; `front/` y backend intactos; ninguna etapa aprobada se modifica salvo el *tooling* de E0 señalado en §4. **El backend de `origin/main` es un borrador temporal y no se consultó como autoridad.**

**Fuentes consultadas:** diseño consolidado v3 (§F.1: «E14 = demo real, checklist §8 del contrato, concurrencia, rendimiento; bloqueada por D5»; §D.4 `sp_cargar_demo`; §G demostración), spec (§7.1 registro, §7.5–7.6, §10 apagón, §11 Compose, §14 frente 5 «QA / Seed / Apagón», §16.4), plan (Task 15: `seed` con funciones reales, `runbook-demo.md`, `e2e/recorrido`), contrato PDF (§4 cambios de esquema, **§5 datos de partida**, §6 mensajes, **§8 checklist de aceptación**), `front/mock/server.mjs` (los datos «idénticos» del §5), `front/` (solo lectura), los diseños de E1, E3 (§14 política de demostraciones, P-DEMO-1/2/3), E4 (D5, usernames fijos), E7–E9 (catálogo vacío, D11), E11–E13 y el código (`registrar_usuario`, guardia de `cuenta`, `_reloj_actualizar`, `v_integridad_*`, `ctl.sh`, `compose.dev.yml`, la suite de 3158 pruebas).

## 1. Alcance

| Entra en E14 | No entra |
|---|---|
| **(a) Catálogo** (CDT y 4 productos de crédito) como script aparte `db/seed/00_catalogo.sql`, idempotente. **(b) Funciones solo-seed** (D5) en un esquema **temporal `seed`** que se crea y se elimina. **(c) Seed demo** `db/seed/20_demo.sql`: admin1, `jperez483` (cuenta `4001002003`), `cgomez12`, `bloqueado1` y ~8 clientes más, creados **solo con funciones reales** moviendo el reloj ~120 días; termina con el reloj **real**, `sp_avanzar_todos` y `v_integridad_global.ok`. **(d) Respaldo/restauración** (P-DEMO-3). **(e) Runbook BD** y **matriz de aceptación del §8** del contrato. **(f) QA:** recorrido de `banco_app` por TCP sobre el seed, reinicio/apagón del contenedor de BD, y un volumen acotado. | Backend, front, Docker final y el e2e con navegador (Task 15 usa el backend: es de Juan/Jose); el cierre «503 sin conexión» (lo emite el backend); nuevas funciones de negocio; cambios en `public` (131 funciones, `banco_app` = 40: **ninguno**); programar `sp_avanzar_todos` (D-E13-D1). |

## 2. Qué dicen las fuentes y qué hallé

| Tema | Hallazgo / resolución |
|---|---|
| **Qué debe contener el seed** (contrato §5) | Admin `admin1`; cliente `jperez483`, cuenta `4001002003`, 2 bolsillos, 2 CDT (1 activo, 1 cerrado), 2 créditos de productos distintos, ~20 movimientos de envío/recibo con nombres colombianos; `bloqueado1`; clave `Banco2026` para todos; 4 productos y CDT con tasas crecientes. El spec añade `cgomez12` (C11) y «créditos corridos en el tiempo vía el reloj, siempre con funciones reales». |
| **No se puede fijar `username`/`numero_cuenta` con la función real** | `registrar_usuario` genera ambos al azar (E4: «no hay parámetros forzar») y `trg_zz_proteger_cuenta` hace **inmutable** `numero_cuenta`. Los usuarios fijos son el motivo de D5. **Resolución:** el usuario se crea con `registrar_usuario` (ingresos, bono, validaciones reales) y, **inmediatamente después y antes de cualquier otra operación**, una función solo-seed fija `username`, `numero_cuenta` y `codigo_referido` con `session_replication_role = replica` (solo superusuario; no hace DDL ni deja `ALTER TABLE` en la auditoría; ojo: el bono del referidor guarda el número de cuenta del nuevo usuario como contraparte, por eso `seed.cliente` registra con verificación activa, fija la identidad y **solo después** verifica el correo; se prueba que ningún asiento menciona un número viejo). El ADMIN se inserta con otra función solo-seed (no tiene cuenta, C.1). |
| **El catálogo sigue siendo del equipo (D11)** | E1/E7/E8: «catálogo vacío hasta que el equipo decida». Hay **contradicciones** (§6). Se propone un catálogo **provisional en un solo archivo** que el equipo puede editar sin tocar nada más. |
| **Reloj del seed** | D5/E3: banco vacío ⇒ el reloj se puede fijar en el pasado; después solo avanza. El seed arranca en `R−120` (hoy real = `R`), avanza por etapas y **vuelve a real en `R`** (siempre permitido): sin patas futuras (`v_reloj_estado`). La *política de demostraciones* (un solo adelanto) rige para la **demostración**, no para la preparación. |
| **Lo guardado vs lo derivado** | El visor Control (E12) muestra lo **guardado**: el seed termina con `CALL sp_avanzar_todos()` (E13) para que Control y pgAdmin muestren el estado al día. |
| **Hash de la clave** | La BD solo guarda bcrypt (`_es_hash_bcrypt`). El seed lleva **un hash fijo de `Banco2026`** generado una vez con `pgcrypto` (cost 10); las pruebas verifican con `crypt()` que corresponde a la clave (extensión solo en la BD de pruebas). |
| **Qué ya está cubierto del §8** | Forma y tipos de las 26 funciones de cliente (`67_contrato`), los 15 mensajes del §6 (≥ 3 pruebas cada uno), +30 días con intereses ya cobrados (`54`/`55`/`reales/45`), 30 años y 360 cuotas < 5 s (`54`, `57`, `58`, `62`), hash nunca visible y FK `referido_por` (`71`, `reales/55`). **No se repiten:** E14 los **traza** en una matriz (§7) y solo prueba lo que falta: el seed real y el recorrido sobre él. |
| **Task 15 del plan** | Pide `seed.sh`, `runbook-demo.md` y `e2e/recorrido.test.ts` (con backend y apagón). Aquí se entrega la parte de **BD** de las tres; el e2e con backend/front queda para Juan/Jose, con la BD lista (seed + runbook). |

## 3. Diseño

**Archivos nuevos** (todos fuera de `db/sql/`, que sigue siendo el esquema; **nada de E1–E13 cambia**):

| Archivo | Contenido |
|---|---|
| `db/seed/00_catalogo.sql` | `cdt_definicion` (3) y `credito_producto` (4) por *upsert* en `nombre`; tasas/mínimos editables; **solo configuración (D11)**: se puede cargar en cualquier banco. |
| `db/seed/10_funciones_seed.sql` | Esquema **`seed`** (dueño: superusuario, sin permisos para nadie más) con `seed.crear_admin(...)`, `seed.fijar_identidad(usuario, username, numero_cuenta, codigo_referido)` y `seed.cliente(...)` (= `registrar_usuario` + `verificar_correo` + `fijar_identidad`, con el hash fijo). Reutilizan `_norm_*`/validaciones de E4 y exigen **banco sin operaciones posteriores** al registro del usuario. |
| `db/seed/20_demo.sql` | La historia, una sentencia por paso (autocommit, como el backend), con el reloj en etapas. Al final: reloj **real**, `CALL sp_avanzar_todos()`, `DROP SCHEMA seed CASCADE`, informe de verificación. **Se niega a correr** si ya hay usuarios (`El seed solo corre sobre un banco vacío`). |
| `ctl.sh` / `ctl.ps1` | Comandos nuevos: `seed [catalogo\|demo]`, `backup [nombre]`, `restore [nombre]`. |
| `docs/db/runbook-demo.md` | Runbook de BD: levantar, aplicar, sembrar, respaldar, ensayar, restaurar, apagón (stop/start db), qué verificar en pgAdmin. |

**La historia del seed** (todo con funciones reales; `setseed(0.2026)` hace reproducibles los ingresos aleatorios; los UUID no):

| Día | Paso |
|---|---|
| `R−120` | Reloj manual (banco vacío). `admin1`; 10 clientes (jperez483, cgomez12, bloqueado1 y 7 con nombres colombianos como los del mock: Felipe Arango, Paula Vargas, Andrés Mora, Laura Ospina, Santiago Gómez…). Un referido de `jperez483` (bono real de $50.000 al verificar). Mora = 30 % con `admin_set_tasa_mora` (valor del mock, provisional). |
| `R−118…R−3` | ~14 envíos entre `jperez483` y los demás en ambos sentidos (`hacer_transferencia`); depósito de `admin1` a `jperez483` con `admin_ajustar_balance` («el banco ha enviado…»). Bolsillos «Viajes» y «Emergencias» con ingresos y un retiro. |
| `R−110` / `R−30` | CDT de 90 días: el primero **cierra** solo (R−20); el segundo queda **activo**. |
| `R−90` / `R−75` | Crédito *Libre inversión* con **descuento automático** (cuotas al día) y crédito *Vehículo* **sin** descuento (cuotas vencidas → **mora** visible en el dashboard). |
| `R−10` | `admin_bloquear('bloqueado1')`. `cgomez12` con bolsillo «Ahorro» y movimientos. |
| `R` | Reloj real; `CALL sp_avanzar_todos()`; verificación: `v_integridad_global.ok`, `v_reloj_estado` (real, 0 patas futuras, banco no vacío), 0 defensas caídas. |

**Respaldo/restauración (P-DEMO-3):** `backup` = `pg_dump -Fc` dentro del contenedor + `docker compose cp` al host (`db/backups/`, con su propio `.gitignore`; **sin** redirigir binarios por PowerShell 5.1); `restore` = terminar conexiones, `DROP/CREATE DATABASE banco` y `pg_restore` con las opciones que dejen los objetos a nombre de `banco_owner` (se validan en las pruebas; mismo clúster: los roles son globales). Se prueba también `CREATE DATABASE … TEMPLATE` como alternativa rápida y se documentan ambas; el criterio es que el estado restaurado tenga **la misma huella** (saldos, libro, reloj, auditoría) y las mismas defensas.

## 4. Archivos de etapas anteriores que se tocan (solo tooling, con tu visto bueno)

| Archivo | Cambio | Por qué |
|---|---|---|
| `db/compose.dev.yml` (E0) | +1 montaje de solo lectura `./seed:/work/seed:ro` (servicios `db` y `pgadmin`) | `psql -f` lee dentro del contenedor (sin *pipes* de PowerShell). Requiere `ctl up` para recrear el contenedor. |
| `db/ctl.sh` y `db/ctl.ps1` (E0) | Los 3 comandos de arriba | Camino único en Windows (`ctl.ps1`) y opcional (`ctl.sh`). |
| `db/tests/mutaciones/mutaciones.sh` | Bloque E14 + variable `SEED_DIR` para mutar una copia de los scripts del seed | Las mutaciones del seed son de texto, no de funciones de BD. |

**No se toca:** `db/sql/*` (cero cambios), `db/tests/*.test.sql` (**ninguna adaptación de inventario**: no hay objetos nuevos en `public`), `front/`, backend, `.gitignore` de la raíz.

## 5. Decisiones

**Técnicas (las aprueba el responsable de BD):**

| ID | Decisión | Recomendación |
|---|---|---|
| **D-E14-1** | Alcance (a)–(f) con el seed y el catálogo **fuera de `db/sql/`**; `sp_cargar_demo` (v3 §D.4) **se reemplaza** por `ctl seed demo` (psql, autocommit). | Aprobar. |
| **D-E14-2** | Funciones solo-seed en esquema **temporal `seed`** (no quedan en el banco; inventario de `public` intacto) y fijación de identidad por `session_replication_role = replica` justo tras `registrar_usuario`. Alternativa: objetos permanentes en `db/sql/27_*` (cambia `03`, `10`, la lista blanca y deja funciones de superusuario en producción). | Aprobar el esquema temporal. |
| **D-E14-3** | Seed **reproducible** (`setseed`) y **solo sobre banco vacío**; el catálogo se carga aparte (idempotente). | Aprobar. |
| **D-E14-4** | Historia del §3 (incluye un crédito *sin* descuento automático para mostrar **mora** y un referido con bono); el contrato pide «2 créditos de distintos productos»: cumple. | Aprobar (alternativa: ambos al día, sin mora visible). |
| **D-E14-5** | Respaldo con `pg_dump -Fc` + `pg_restore` por `ctl backup/restore`, con la plantilla como alternativa documentada. | Aprobar. |
| **D-E14-6** | **P-DEMO-1/2 (E3):** no añadir guarda en BD para «un solo adelanto» (alternativa 0: política + restaurar); si lo quieres, la alternativa 3 (marca `DEMO_BASE` puesta por el seed) cabe aquí con ~4 pruebas. | **No** añadirla ahora. |
| **D-E14-7** | Volumen **acotado y opcional**: `reales/59_volumen` con ~300 clientes (~20.000 patas) por funciones reales, para medir la búsqueda trigram de admin, `admin_tabla` y `sp_avanzar_todos` con trabajo real, y guardar los `EXPLAIN` como evidencia. | Aprobar (alternativa: omitirlo; E1/E10 ya tienen `EXPLAIN` del historial). |

**Pendientes del equipo (no se deciden aquí; todas provisionales, centralizadas en `db/seed/00_catalogo.sql`/`20_demo.sql`):**
* **D-E14-D1 (= D11):** nombres, tasas, montos y plazos del catálogo. Propuesta provisional: **créditos** según el **spec §7.6** (Libre inversión 24 m, tope $30M; Vehículo $50M–$200M, 120 m; Educación $1M–$100M, 240 m; Inmuebles 360 m, tope `min(100×balance, $2.000M)`, regla de edad) con las **tasas del mock** (23,9 / 18,9 / 15,4 / 14,1 % E.A.); **CDT** de 90, 180 y 360 días con las tasas del mock (9,25 / 10 / 10,75 %) y mínimo **$100.000** (el sugerido por el contrato §4; el mock dice 500.000/1M/2M).
* **D-E14-D2:** clave demo `Banco2026` y datos **ficticios**; el runbook advierte que **no es para producción**.
* **D-E14-D3:** mora = 30 % solo en el seed demo (valor del mock; D7 sigue abierta).
* **Coordinación con Jose (Docker):** cómo se ejecutan `apply` + `seed` en `docker compose up` (hoy: manual con `ctl`). **No se toca** su Compose.

## 6. Contradicciones y ambigüedades

(a) **Nombres de producto:** mock «Vivienda/Educativo» vs spec «Inmuebles/Educación» (el contrato pide elegir: se propone el spec). (b) **Montos del mock vs spec:** el crédito de Vehículo de $12M del mock **viola** el mínimo de $50M del spec: el seed crea uno de ≥ $50M (el valor visible del front cambia respecto del mock). (c) **CDT:** 90/180/360 días (mock) vs 6-12-24-36 meses (spec): el contrato dice que sirve cualquiera; mínimo $100.000 (contrato) vs 500.000/1M/2M (mock). (d) **Bolsillos:** contrato «Viajes/Emergencias» vs mock «Viaje a San Andrés/Fondo de emergencia» (se usa el contrato). (e) **`admin1` con `numero_cuenta`** en el mock; en la BD el ADMIN **no tiene cuenta** (C.1). (f) **`cgomez12`** no sigue la regla de username (C11): solo posible con función solo-seed. (g) «~20 transacciones» no define qué se cuenta (se garantizan ≥ 20 filas visibles en el historial de `jperez483`). (h) El plan manda `db/seed/seed.sh` y el e2e con backend; aquí se entregan comandos `ctl` y la parte de BD. (i) v3 §D.1 numeraba `17_seed_productos` dentro de `db/sql`; E1 dejó el catálogo fuera, y se mantiene.

## 7. Plan de pruebas (solo riesgos nuevos; no se repiten E1–E13)

| Archivo | Riesgo que cubre | Aserciones ≈ |
|---|---|---|
| `reales/57_seed.sh` (BD propia `banco_seed`: aplica `db/sql`, siembra, verifica y la elimina) | **Catálogo** (los 4+3 valores, topes y regla de edad del spec; idempotencia: 2.ª carga = 0 cambios); **identidad** (`jperez483`, `cgomez12`, `admin1`, `bloqueado1`, cuenta `4001002003`, códigos de referido fijos; ningún asiento ni snapshot referencia la cuenta aleatoria vieja; ADMIN sin cuenta); **clave** (el hash coincide con `Banco2026` por `crypt()` y `obtener_credenciales` lo entrega); **la historia** (2 bolsillos, 2 CDT 1 activo + 1 cerrado, 2 créditos de productos distintos, 1 con mora, ≥ 20 filas de historial con envíos y recibos, bono real, `bloqueado1` bloqueado con el mensaje exacto); **estado final** (reloj real, 0 patas futuras, `v_integridad_global.ok`, 0 defensas caídas, banco no vacío, esquema `seed` eliminado, 1 evento `MANTENIMIENTO_AVANZAR`, segunda corrida de `sp_avanzar_todos` = 0 grupos, 131 funciones, `banco_app` = 40); **se niega** sobre un banco con usuarios; **reproducible** (dos siembras con `setseed` dan los mismos ingresos). **Recorrido de `banco_app` por TCP** (sin superusuario) con la sesión de `jperez483`: perfil, dashboard, historial, bolsillos, CDT, créditos, simulaciones; `cgomez12` envía a `4001002003`; `bloqueado1` recibe el mensaje de bloqueo; `admin1` usa `admin_esquema`/`admin_tabla`/`admin_listar_usuarios` | ≈ 55 |
| `reales/58_respaldo.sh` | `backup` → operar (envío, reloj +10) → `restore` = **misma huella** (saldos, libro, reloj, auditoría) y defensas en orden; restaurar dos veces; plantilla como alternativa; restaurar con conexiones activas (se cierran) | ≈ 12 |
| `reales/59_volumen.sh` *(opcional, D-E14-7)* | ~300 clientes por funciones reales; búsqueda de admin usa el índice trigram (`EXPLAIN` + tiempo); `admin_tabla` página N de `transaccion`; `sp_avanzar_todos` con trabajo real en todas las cuentas dentro de una cota; integridad intacta; evidencia `EXPLAIN` | ≈ 10 |
| **Manual, con evidencia** (`14-apagon-bd.txt`) | `docker compose stop db` → `start db` (con `ctl`): datos intactos, `pg_isready`, `v_integridad_global.ok`, sin pasos extra; `down` sin `-v` conserva el volumen | — |

**Matriz de aceptación del §8** (en `14-seed-qa.md`): cada ítem del checklist → archivo de prueba y evidencia que ya lo prueba, más el comando que lo reproduce; los 3 ítems que dependen del backend («reemplazar el mock endpoint por endpoint») se marcan **fuera de la BD** y se entrega la tabla maestra completa E4–E13 para Juan.

**Estimado: ≈ +77 aserciones; ≈ 14 mutaciones (M468…):** catálogo con un valor alterado (nombre, tope de Libre, regla de edad de Inmuebles, mínimo de CDT), identidad sin fijar o fijada tras otra operación, ADMIN con cuenta, hash que no corresponde, reloj final en manual, sin `sp_avanzar_todos` final, esquema `seed` sin eliminar, seed sobre banco no vacío sin negarse, `bloqueado1` sin bloquear, restauración que no limpia. **Sin regresión de las 64 anteriores**: no se modifica código de `db/sql`.

## 8. Riesgos y límites

1. **Los montos de los ingresos y los UUID cambian entre siembras** (los usernames, cuentas y códigos fijos no); `setseed` fija solo los `random()`.
2. **La identidad fija usa `session_replication_role = replica`** (solo superusuario): es la misma capacidad del superusuario que E2 ya documenta como límite; no queda ningún objeto ni permiso nuevo.
3. **El seed mueve el reloj varias veces** (permitido solo por la preparación); termina en real. Si se interrumpe a la mitad, el banco queda **no vacío y con reloj manual**: `ctl reset --yes` + `apply` + `seed`.
4. **El seed no es idempotente a propósito** (solo banco vacío); el catálogo sí lo es.
5. **El backup incluye `audit.evento` y `reloj`**; los roles son globales: restaurar solo en el **mismo clúster** (documentado en el runbook).
6. **Cualquier decisión del equipo que cambie cifras** (D1 tasas, D6 balance total, D7 mora, D11 catálogo) cambia lo que muestra el seed: está escrito con funciones reales, así que **se actualiza solo** al re-sembrar; las pruebas del seed afirman estructura y reglas, no cifras monetarias exactas.
7. **El e2e con backend/front y el apagón visible (banner 503) no se pueden probar en la BD**: se entrega el runbook y el estado de la BD que lo permiten; los ejecutan Juan, Daniel García y Jose.
