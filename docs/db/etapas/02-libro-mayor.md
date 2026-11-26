# Etapa 2 — Libro mayor y guardias · paquete de entrega

**Estado:** ✅ **APROBADA por el responsable de BD (2026-11-21)** tras su auditoría independiente; desviaciones aceptadas. Consideraciones para etapas posteriores: (1) las funciones de negocio escriben el libro **solo** con `_asentar_grupo`, sin inserciones directas; (2) en E7 el CDT y su grupo `CDT_CREACION` se ejecutan uno inmediatamente después del otro en la misma transacción; (3) las limitaciones del superusuario siguen documentadas (vistas y auditoría **detectan**, no protegen de forma absoluta); (4) no se tocan las decisiones financieras pendientes del equipo. Siguiente: [E3 — Reloj (diseño)](03-reloj-diseno.md). **Sin commits** (todo sigue sin versionar en `feat/db-core`). No se tocó `front/`, backend, `docs/specs`, `docs/superpowers` ni archivos de otros integrantes. No se tomó ninguna decisión financiera pendiente (D1, D4, D6, D7, D8, D10–D13): no hay intereses, cuotas, mora, abonos ni reloj; los grupos de `CREDITO_CUOTA/ABONO/MORA` solo tienen reglas de coherencia (D-E2-1).

Diseño aprobado: [02-libro-mayor-diseno.md](02-libro-mayor-diseno.md) · E1: [01-esquema.md](01-esquema.md).

## 1. Qué se entrega

| # | Entregable | Dónde |
|---|---|---|
| 1 | **Scripts SQL** (4 nuevos + 1 ajustado) | `db/sql/06_libro_mayor_estructura.sql`, `07_libro_mayor_funciones.sql`, `08_libro_mayor_triggers.sql`, `09_integridad.sql`; `05_permisos.sql` (ajustado) |
| 2 | **Pruebas automatizadas** | `db/tests/10…18_*.test.sql` (SQL), `db/tests/reales/19…29_*.sh` (conexiones reales y concurrencia, dentro del contenedor), `db/tests/harness.sql`, `db/tests/mutaciones/mutaciones.sh`; las de E1 adaptadas (sección 6) |
| 3 | **Resultados** de concurrencia, aleatorias y mutaciones | `docs/db/evidencias/02-libro-mayor.txt` (836 aserciones), `02-libro-mayor-mutaciones.txt`, `02-libro-mayor-aleatorio.txt` |
| 4 | **Evidencias de conexiones reales** | en `02-libro-mayor.txt`, secciones `reales/19`, `20`, `21` (banco_app, ledger_probe→banco_ledger, banco_lector, banco_dev) |
| 5 | **Documentación actualizada** | este archivo, el diseño (con las desviaciones), `docs/db/00-entorno.md`, `COMMENT` en cada función, trigger, vista y columna nueva |
| 6 | **Guía de verificación en pgAdmin** | sección 8 de este archivo + `docs/db/evidencias/02-pgadmin-demo.sql` + 3 capturas de la demo ejecutada en pgAdmin (`docs/db/evidencias/capturas-pgadmin/e2-*.jpg`: resumen de integridad y los mensajes de la demo con cada intento prohibido rechazado) |
| 7 | **Ejecución limpia + 3 aplicaciones** | `docs/db/evidencias/02-libro-mayor-aplicacion.txt` (reset + 3 × `apply`: 0 líneas con ERROR/FATAL) |

## 2. Resultado de un vistazo

| Verificación | Resultado |
|---|---|
| Suite completa (`db\ctl.cmd test`) | **836 aprobadas, 0 fallidas** (E1: 352 · E2 SQL: 332 · conexiones reales y concurrencia: 152) |
| Ejecución desde cero | `reset` + 3 × `apply`: **0 errores** (10 archivos; catálogo: 11 tablas en `public` + `audit.evento`, 15 funciones, 12 triggers, 2 event triggers, 5 vistas) |
| Mutaciones | **24 de 24 detectadas** (cada una rompe una defensa a propósito) |
| Prueba aleatoria | 3000 iteraciones en la suite; corrida pesada de 15000 (`02-libro-mayor-aleatorio.txt`): **12 995 operaciones válidas** de las 14 clases (≈ 1000 de cada una; 157–168 de cuota/abono), **4 444 grupos mutados inválidos: 4 444 rechazados, 0 aceptados, 0 con rastro**; integridad global en orden, conservación del dinero y sin saldos negativos |
| Concurrencia | 0 deadlocks y 0 saldos incorrectos en los 6 escenarios (sección 5) |
| Rendimiento | ≈ 4,7 ms por grupo (2 patas) con todos los triggers, bloqueos y cuadre inmediato, cada grupo en su transacción |
| Tablas | `public` sigue con **exactamente 11 tablas**; `audit.evento` en `audit` |

## 3. Cómo funciona (resumen)

```
función de negocio (E4+, SECURITY DEFINER de banco_owner)
   └─ public._asentar_grupo(fecha, patas jsonb)        ÚNICO escritor autorizado
        1  exige READ COMMITTED y valida el JSON (errores limpios, P0001)
        2  bloquea las CUENTAS en orden de id (FOR NO KEY UPDATE)       ← sin deadlocks
        3  inserta las patas en orden determinista
              BEFORE INSERT  trg_transaccion_a_validar   fuerza registrado_en/tx_id, descarta saldos del llamador,
                                                          sella el grupo, comprueba que cada producto es de la cuenta
              BEFORE INSERT  trg_transaccion_b_aplicar   (dueño banco_ledger) calcula saldo previo/posterior y
                                                          ACTUALIZA el acumulador ← único camino que mueve saldos
        4  SET CONSTRAINTS ... IMMEDIATE: ct_transaccion_cuadre (ΣD=ΣC, plantilla, sellado, misma fecha, par ENVIO/RECIBO)
                                          ct_cdt_inversion (invariantes del CDT)
        5  cualquier error ⇒ se revierte TODO el grupo
   guardias trg_zz_proteger_* (SECURITY INVOKER): un UPDATE de acumulador solo vale si current_user = banco_ledger
                                                 y pg_trigger_depth() > 1 (lo dispara el trigger del libro)
   libro inmutable: UPDATE/TRUNCATE siempre rechazados; DELETE solo si la cuenta de la pata ya no existe (cascada)
   verificación independiente: v_integridad_saldos / grupos / usuario / global / defensas
```

## 4. Garantías pedidas → cómo se cumplen y dónde se prueban

| Garantía | Mecanismo | Pruebas |
|---|---|---|
| **Ningún saldo se modifica directamente** | Capa 1: ni el dueño ni nadie tiene `UPDATE` de acumuladores (solo `banco_ledger`, por columna). Capa 2: el guardia rechaza todo cambio fuera de contexto confiable, incluso de `banco_ledger` fuera del trigger y de un superusuario. Capa 3: los saldos que traiga el llamador se descartan | `11_libro_guardias` (UPDATE como superusuario, dueño, ledger, app, dev, lector sobre los 4 acumuladores), `reales/19` (función definer defectuosa), `reales/20` (conexión real que asume `banco_ledger`) |
| **Partida doble y plantillas en todos los grupos** | `ct_transaccion_cuadre` diferido (al COMMIT) **y** inmediato dentro de `_asentar_grupo`: ≥2 patas, ΣD=ΣC, una transacción y una fecha, 15 plantillas, coherencia de producto y de cuenta, dinero entre cuentas solo en par ENVIO/RECIBO. **Créditos sin plantilla (D-E2-1):** todas las patas de crédito, de **una** cuenta propietaria, de **un** mismo crédito, sin transferencias y con cuadre | `12`, `13` (33 casos), `14`, `17` (miles de grupos válidos y mutados), `reales/26` |
| **Atomicidad** | Una llamada = una sentencia = una transacción; subtransacción en `_asentar_grupo`; sin `COMMIT` internos | `12` (fallo a mitad de grupo), `reales/19` (ROLLBACK y corte de conexión), `reales/26` (pata suelta falla en el COMMIT y revierte el saldo; corte a mitad de grupo) |
| **Bloqueos en orden determinista** | Cuentas por id ascendente (`ORDER BY id FOR NO KEY UPDATE`); patas en orden `(cuenta, contenedor, producto, sentido)`; `FOR NO KEY UPDATE` no frena las FK ajenas | `12` (orden de inserción), `reales/23` (A↔B 2×200), `reales/24`, mutación M21 |
| **Historial inmutable** | `trg_transaccion_inmutable` (UPDATE nunca; DELETE solo si la cuenta ya no existe), `BEFORE TRUNCATE`, el dueño pierde `UPDATE`/`TRUNCATE`, `registrado_en` y `tx_id` forzados, sellado por `tx_id`; auditoría `CUENTA_BORRADA`; event triggers de DDL | `15`, `reales/26`, mutaciones M08–M10 |
| **Las vistas detectan inconsistencias y defensas caídas** | `v_integridad_*`: saldos (I1/I2), grupos (I3/I7), usuario (I5u), global (I5g) y 24 controles de defensas (I9) | `16` (≈30 sabotajes aplicados y deshechos: saldos alterados, grupos inventados, triggers apagados/borrados, grants, roles, owners, EXECUTE, event triggers) |
| **Conexiones reales con permisos efectivos** | Sesiones TCP con contraseña dentro del contenedor | `reales/19` (banco_app: 22 denegaciones + camino con funciones arnés + forjados), `20` (sonda → `banco_ledger`: 37), `21` (lector y dev) |
| **Sin deadlocks ni saldos incorrectos** | Protocolo de bloqueo + saldo leído tras el bloqueo | `reales/22` (6 retiros simultáneos: gana 1), `23`, `24` (8 sesiones × 250 transferencias aleatorias + verificador concurrente), `25`, `26` |

### Roles privilegiados (tu precisión sobre D-E2-3)
* `banco_owner` y `banco_ledger` siguen **NOLOGIN**, sin atributos especiales: lo prueba `10`, el control de `v_integridad_defensas`, `reales/19` (intento de login real rechazado) y `reales/21`.
* **Ningún rol de aplicación puede asumirlos**: `pg_has_role(app|dev|lector, owner|ledger, MEMBER|USAGE|SET)` es siempre falso (`10`); `SET ROLE banco_owner/banco_ledger` desde conexiones reales de `banco_app`, `banco_dev` y `banco_lector` termina en *permission denied* (`reales/19`, `21`); además la vista de defensas detecta cualquier miembro (probado con la propia sonda en `reales/20`).
* **`SELECT` mínimo de `banco_ledger`** (afinado en `05_permisos.sql`): 11 columnas, **ningún** privilegio de tabla: `cuenta(id, balance)`, `bolsillo(id, cuenta_id, balance)`, `cdt(id, cuenta_id, generado_acumulado)`, `credito(id, cuenta_id, capital_pendiente)`. Es exactamente lo que usa su única función. `08` lo fija, `reales/20` lo prueba con una conexión real (puede leer eso y bloquear la fila; **no** puede leer `numero_cuenta`, `monto`, `usuario`, el libro ni la auditoría) y la mutación M19 verifica que una concesión extra se detecta.
* **`ledger_probe`** (D-E2-4): rol-sonda `LOGIN`, `NOINHERIT`, miembro de `banco_ledger`, solo para pruebas. Su eliminación está garantizada por **cuatro** capas: `trap EXIT/INT/TERM` en `reales/20`; el `try/finally` de `ctl.ps1 test` (y `trap EXIT` en `ctl.sh`) que ejecutan `db/tests/reales/limpiar_sonda.sql` **antes y después** de la corrida; la propia prueba que comprueba que `to_regrole('ledger_probe')` es NULL y que la sonda ya no puede conectarse; y la verificación final del runner (aserción "el rol-sonda NO existe tras las pruebas reales"). Comprobado también al final: `SELECT rolname FROM pg_roles WHERE rolname='ledger_probe'` → 0 filas.

## 5. Resultados de concurrencia (dentro de `02-libro-mayor.txt`)

| Escenario | Resultado |
|---|---|
| `reales/22` — 6 conexiones de `banco_app` mueven 800 de una cuenta con 1000 a la vez | **1** gana, **5** reciben `Saldo insuficiente`; cuenta 200 y bolsillo 800; 0 otros errores |
| `reales/23` — A→B ∥ B→A, 200 transferencias cada una | 400 grupos, **0 deadlocks**, 0 errores, saldos exactos (100000/100000), +800 patas |
| `reales/24` — 8 sesiones × 250 transferencias aleatorias entre 6 cuentas + 25 lecturas concurrentes de las vistas | 2000 resueltas, 0 errores, **0 deadlocks**, suma 600000.00 constante, **25/25** respuestas del verificador con 0 desvíos (sin falsos positivos) |
| `reales/25` — camino NO sancionado (INSERT directo pata por pata) contra el sancionado | sin corrupción: 0 grupos incompletos, saldos = patas, dinero conservado (un deadlock aquí lo resolvería PostgreSQL; es el costo de no usar `_asentar_grupo`) |
| `reales/26` — atomicidad y sellado con transacciones reales | pata suelta falla en el COMMIT y el saldo revierte; grupo confirmado no se amplía; corte de conexión a mitad de grupo sin rastro; una sesión que sostiene el bloqueo serializa a la otra (≥ 1 s de espera) |
| Mutación M21 | sin bloqueo ni inserción ordenados la prueba lo detecta (`12`; el deadlock real de ese patrón se demostró en el laboratorio de diseño) |

## 6. Desviaciones respecto al diseño aprobado (todas con su porqué)

| # | Desviación | Porqué / efecto |
|---|---|---|
| 1 | **`banco_owner` conserva `UPDATE(registrado_en)` en `transaccion`** (diseño: perdía todo `UPDATE`). También `cdt(definicion_id)` | Al borrar un bolsillo/CDT/crédito, la FK `NO ACTION` del libro se comprueba con `SELECT … FOR KEY SHARE` sobre `transaccion` **con los privilegios de su dueño**, y ese bloqueo exige algún `UPDATE`. Sin él, el borrado en cascada de un usuario falla con *permission denied* (lo descubrió la prueba de borrado). La columna es inocua: el trigger rechaza **todo** `UPDATE` del libro. `definicion_id`: la FK `SET NULL` actualiza esa columna como dueño. Documentado en el encabezado de `06`; vigilado por `v_integridad_defensas` |
| 2 | **`ct_transaccion_cuadre` y `ct_cdt_inversion` son `SECURITY DEFINER`** (diseño: invoker) | Un trigger diferido se dispara **al COMMIT con el usuario de la sesión** (p. ej. `banco_app`, que no puede leer `transaccion`): como invoker fallaba con *permission denied* en vez de dar el error real. Como definer (dueño `banco_owner`, SQL estático, `search_path` fijo) siempre puede leer el libro. Lo descubrió `reales/19` |
| 3 | **`EXECUTE` de `_plantillas_validas()` para `banco_lector`** (y `banco_dev` por herencia) | Las funciones que llama una vista se ejecutan con los privilegios de quien consulta la vista; `v_integridad_grupos` la usa. Es un catálogo de constantes. `banco_app` y `PUBLIC` siguen sin poder ejecutarla; el control de defensas lo contempla |
| 4 | **`05_permisos.sql` modificado**: `banco_ledger` pasa de `SELECT` de tabla a `SELECT` por columna (11 columnas), y se re-conceden a `banco_lector` las vistas `v_integridad_*` si existen | Tu petición de permisos mínimos; y para que reaplicar solo `05` no deje al lector sin las vistas (el `REVOKE ALL ON ALL TABLES` también cubre vistas). Las pruebas `08` y `09` se actualizaron |
| 5 | **Un CDT debe crearse junto con su grupo `CDT_CREACION`** | Consecuencia de la regla (aprobada) de coherencia del CDT: `SET CONSTRAINTS … IMMEDIATE` evalúa **todos** los eventos pendientes, así que un CDT sin su pata de apertura hace fallar cualquier grupo siguiente de esa transacción. La función de negocio (E7) debe insertar el CDT y asentar su apertura de inmediato (así lo hacen todas las pruebas) |
| 6 | **Los triggers de restricción se recrean con `DROP TRIGGER IF EXISTS` + `CREATE CONSTRAINT TRIGGER`** | PostgreSQL no admite `CREATE OR REPLACE CONSTRAINT TRIGGER`. Dentro de la misma transacción, idempotente |
| 7 | **Pruebas de E1 adaptadas con `ALTER TABLE … DISABLE TRIGGER USER` en lugar de `session_replication_role = replica`** | Tu precisión: `replica` también apaga los triggers internos de las FK. `DISABLE TRIGGER USER` apaga **solo** los triggers de usuario (libro mayor, guardias, auditoría) y deja las FK **activas y con su comportamiento normal**, así las pruebas de FK de `04`, `05`, `06` siguen siendo independientes (siguen probando `fk_*` con 23503). Es más estricto que lo autorizado. `replica` solo se usa en `16`, como *sabotaje* para demostrar que los datos malos se detectan igual |
| 8 | **Orden de los archivos `reales/`** como pruebas separadas del runner | Las pruebas de conexiones reales y concurrencia son scripts `sh` que corren **dentro** del contenedor (no dependen de Bash/PowerShell del host); `ctl` los ejecuta tras las SQL |
| 9 | **Ruido de auditoría DDL**: reaplicar los scripts (y pruebas que alteran tablas) registra eventos `DDL` en `audit.evento` | Es el comportamiento pedido (trazabilidad de `ALTER TABLE`/`DROP TRIGGER` sobre objetos protegidos). Tras `reset` + 3 `apply` hay 10 eventos `DDL`; las pruebas filtran por `accion`/`entidad_id` |
| 10 | **Corrida aleatoria por defecto de 3000 iteraciones** (parámetro `-v n_iter=N`) | Mantiene la suite en ≈ 1,5 min; la corrida pesada (15000) está en la evidencia |

Pruebas de E1 modificadas (todas conservan su significado; 349 → 352 aserciones): `03` (inventario exacto de las 15 funciones, 12 triggers y 5 vistas en lugar de "ninguna"), `04`, `05`, `06` (`sin_triggers_de_usuario()` al inicio; las FK siguen activas), `08` (permisos del dueño y de `banco_ledger` afinados), `09` (reaplica 00–09 y la huella incluye funciones, triggers, event triggers, vistas y permisos por columna), `helpers.sql` (`huella_catalogo` ampliada).

## 7. Límites (honestidad)

* **Superusuario:** PostgreSQL no se defiende de él (`ALTER TABLE … DISABLE TRIGGER`, `session_replication_role = replica`). Mitigación: ningún rol de uso diario lo es; los event triggers auditan los `ALTER TABLE`/`DROP TRIGGER` sobre objetos protegidos (probado); `v_integridad_defensas` detecta triggers apagados o borrados y permisos indebidos; `v_integridad_*` detectan los **datos** malos aunque los triggers estuvieran apagados (probado con `replica`). `session_replication_role` no es DDL: no queda en la auditoría, solo sus efectos en los datos.
* **Errores diferidos:** una inserción directa mal armada falla *en el COMMIT*; el camino sancionado (`_asentar_grupo`) los detecta antes y los entrega como `P0001`. `READ COMMITTED` obligatorio.
* **Borrado de cuentas:** destruye saldos; deja la pata del otro cliente "sola" (clasificada `HUERFANO_POR_BORRADO` solo si su `contraparte_cuenta` ya no existe; si existe, es ERROR). Un número de cuenta borrado y reutilizado ocultaría un error real (probabilidad despreciable; los números los asigna E4).
* **`fecha` sin validar** hasta E3. `mora_acumulada` sigue editable por el dueño hasta decidir D7.
* **Mensajes:** solo `Saldo insuficiente` y `Monto inválido` son del contrato; el resto son internos (`Libro mayor: …`, P0001); la lista para el usuario sigue siendo D13.
* **Rendimiento:** medido con grupos en transacciones separadas. Asentar miles de grupos dentro de **una** transacción acumula subtransacciones y se degrada; no es el patrón del backend.
* Las pruebas con `banco_ledger` usan el rol-sonda (es `NOLOGIN` por diseño). Las pruebas de `reales/` se ejecutan en `banco_test`; las de mutación en bases temporales y **reparan los roles** (globales) antes de cada mutación y al terminar.

## 8. Guía de verificación desde pgAdmin

Prerrequisito: `db\ctl.cmd up`, `db\ctl.cmd apply` (aplica 00–09) y, si ya tenías pgAdmin, `db\ctl.cmd pgadmin-servers`. Conexiones (*Object → Connect Server*): **administración (postgres)**, **banco_dev**, **banco_app**, **banco_lector**. Base `banco`, *Tools → Query Tool*.

### A. Con "administración (postgres)" — inventario
```sql
-- 1) Los 12 triggers de usuario, sus tablas, si están habilitados y si son diferidos (los ct_*)
SELECT c.relname AS tabla, t.tgname AS trigger, t.tgenabled AS habilitado, t.tgdeferrable AS diferible, t.tginitdeferred AS diferido
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE NOT t.tgisinternal ORDER BY 1, 2;

-- 2) Funciones: dueño, SECURITY DEFINER/INVOKER y quién puede ejecutarlas (proacl)
SELECT proname, pg_get_userbyid(proowner) AS dueno, prosecdef AS definer, proacl
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname ~ '^(_|trg_|ct_)' ORDER BY 1;

-- 3) Event triggers y columnas nuevas
SELECT evtname, evtevent, evtenabled FROM pg_event_trigger;
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'transaccion' AND column_name IN ('registrado_en', 'tx_id');

-- 4) Roles: NOLOGIN y sin miembros
SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname IN ('banco_owner', 'banco_ledger');
SELECT g.rolname AS rol, m.rolname AS miembro FROM pg_auth_members a JOIN pg_roles g ON g.oid = a.roleid JOIN pg_roles m ON m.oid = a.member WHERE g.rolname IN ('banco_owner', 'banco_ledger');
```
*Esperado:* 12 triggers (`ct_*` diferidos), `trg_transaccion_b_aplicar` con dueño `banco_ledger` y `definer`, las guardias `trg_zz_proteger_*` **sin** `definer`, 2 event triggers, ambas columnas, `banco_owner`/`banco_ledger` con `rolcanlogin = f` y la segunda consulta **sin filas**. En el árbol: *Schemas → public → Functions / Triggers / Views* (cada objeto tiene su *Comment*).

### B. Verificación independiente (también con **banco_lector** y **banco_dev**)
```sql
SELECT * FROM public.v_integridad_global;                 -- ok = true, todo en cero en una base vacía
SELECT * FROM public.v_integridad_defensas ORDER BY 1;    -- 24 controles, todos ok = true
SELECT * FROM public.v_integridad_defensas WHERE NOT ok;  -- debe devolver 0 filas
```

### C. Demostración completa sin dejar datos (administración)
Abrir `docs/db/evidencias/02-pgadmin-demo.sql` (o pegarlo) y ejecutar **completo con F5**. Va dentro de `BEGIN … ROLLBACK` y captura cada intento prohibido, así que no se aborta; los resultados salen en la pestaña **Messages**. Esperado: 1) cuentas en 0; 2) ingreso 1000; 3) transferencia 300 (700/300) y el saldo previo→posterior fijado por el libro; 4) integridad `ok=t`; 5) `UPDATE` directo de balance **rechazado**; 6) grupo descuadrado **rechazado**; 7) `Saldo insuficiente`; 8) dinero entre cuentas fuera de un par ENVIO/RECIBO **rechazado**; 9–11) `UPDATE`/`DELETE`/`TRUNCATE` del libro **rechazados**; 12) al borrar a Beto queda `CUENTA_BORRADA` con su estado contable y un grupo `HUERFANO_POR_BORRADO`. La última consulta confirma 0 cuentas y 0 patas. (Las capturas `e2-*.jpg` se hicieron en el panel angosto de la app con una versión compacta de la demo —sin el paso 8 ni la línea de grupos huérfanos—; los resultados completos están en `02-libro-mayor.txt` y se reprodujeron por psql.)

### D. Con **banco_app** (el backend): no puede ver ni hacer nada de esto
```sql
SELECT * FROM public.cuenta;                               -- ERROR: permission denied for table cuenta (42501)
UPDATE public.cuenta SET balance = balance + 1000000;      -- ERROR: permission denied
SELECT public._asentar_grupo(now(), '[]'::jsonb);          -- ERROR: permission denied for function _asentar_grupo
SELECT * FROM public.v_integridad_global;                  -- ERROR: permission denied for view
SET ROLE banco_owner;                                      -- ERROR: permission denied to set role
```
### E. Con **banco_lector** / **banco_dev**
`SELECT * FROM public.v_integridad_global;` funciona; `SELECT password_hash FROM public.usuario;`, cualquier `UPDATE`/`INSERT`/`DELETE` y `SELECT public._asentar_grupo(now(), '[]')` fallan con *permission denied*.

### F. Ejecutar los scripts desde pgAdmin
Query Tool → *Open File* → `/work/sql/06_libro_mayor_estructura.sql` … `09_integridad.sql` → F5 (idempotentes, sin metacomandos de psql). Ejecutarlos como **administración (postgres)**.

## 9. Cómo ejecutar todo

```powershell
db\ctl.cmd up
db\ctl.cmd reset -Yes ; db\ctl.cmd apply ; db\ctl.cmd apply ; db\ctl.cmd apply   # desde cero + 3 aplicaciones
db\ctl.cmd test -Evidence 02-libro-mayor     # 836 aserciones: SQL + conexiones reales + concurrencia
db\ctl.cmd test 12                           # solo las pruebas cuyo nombre empieza por 12 (también filtra reales/)
```
Corrida aleatoria pesada y mutaciones:
```powershell
docker compose -f db\compose.dev.yml exec -T db psql -X -v n_iter=15000 -U postgres -d banco_test -f /work/tests/17_libro_aleatorio.test.sql
docker compose -f db\compose.dev.yml exec -T db sh -c "tr -d '\r' < /work/tests/mutaciones/mutaciones.sh | sh -s"
```
(la corrida pesada necesita una `banco_test` recién creada: `ctl test 17` la recrea).

## 10. Lista de verificación

- [x] 06–09 aplican desde cero y 3 veces seguidas sin errores; 09 de pruebas comprueba que el catálogo (incl. funciones, triggers, vistas y permisos por columna) queda idéntico
- [x] `public` = 11 tablas; `audit.evento` en `audit`
- [x] `banco_owner` y `banco_ledger` NOLOGIN y no asumibles por ningún rol de aplicación
- [x] `banco_ledger`: SELECT mínimo (11 columnas) y UPDATE de 4 acumuladores
- [x] Ningún saldo modificable directamente (superusuario, dueño, ledger fuera del trigger, app, dev, lector)
- [x] Partida doble, plantillas (15) y coherencia de grupos de crédito sin plantilla
- [x] Atomicidad (rollback, corte de conexión, pata suelta en el COMMIT)
- [x] Bloqueos en orden determinista; 0 deadlocks en concurrencia
- [x] Historial inmutable (salvo cascada de cuenta) con trazabilidad (`registrado_en`, `tx_id`, `CUENTA_BORRADA`, event triggers)
- [x] Vistas de integridad detectan inconsistencias y defensas caídas (≈ 30 sabotajes)
- [x] Conexiones reales con `banco_app`, `banco_ledger` (sonda), `banco_lector`, `banco_dev`
- [x] `ledger_probe` creado y eliminado con garantía
- [x] Mutaciones 24/24; aleatorias; documentación; guía de pgAdmin
- [x] No se tocó front/backend; no hay decisiones financieras pendientes adelantadas; sin commits

**Detenido. Espero tu auditoría; no se empezó E3.**
