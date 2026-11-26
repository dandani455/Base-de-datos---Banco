# Etapa 6 — Bolsillos y vista de balance · paquete de entrega

**Estado (2026-11-24): COMPLETADA — APROBADA oficialmente por el responsable de BD tras su auditoría (sin cambios de código).** Sin commits; `front/` y backend intactos; E5 sin modificar en E6. Diseño aprobado: `06-bolsillos-diseno.md` (D-E6-1..9 aprobadas; D-E6-7 resuelta por el contrato: `vista_balance` entra en E6). Resumen para el backend: `06-resumen-para-juan.md`.

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| 5 públicas (`crear_bolsillo`, `mover_a_bolsillo`, `retirar_de_bolsillo`, `mover_entre_bolsillos`, `vista_balance`) + 4 helpers internos (`_reglas_bolsillo`, `_bolsillo_propio`, `_mover_bolsillo`, `balance_total`) | `db/sql/16_bolsillos.sql` (idempotente, como `banco_owner`; las 5 públicas `SECURITY DEFINER`) |
| Lista blanca de `banco_app`: 7 → **12** funciones | `db/sql/09_integridad.sql` (`v_integridad_defensas`) |
| Pruebas nuevas | `db/tests/52_bolsillos.test.sql` (60), `53_bolsillos_aleatorio.test.sql` (7), `reales/43_bolsillos_conexiones.sh` (93), `reales/44_bolsillos_concurrencia.sh` (21) = **181** |
| Pruebas adaptadas (solo inventario) | `03_schema` (61 funciones), `10_libro_triggers` (60 de `banco_owner`, definer y lista blanca de 12), `09_idempotencia` (re-aplica también el 16) |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M114–M136** (23 nuevas) |
| Evidencias | `docs/db/evidencias/06-bolsillos*.txt`, `06-pgadmin-demo.sql` y su salida |

## 2. Cómo funciona (resumen)

* **Movimientos** (`mover_a_bolsillo` = cuenta → bolsillo, `retirar_de_bolsillo` = bolsillo → cuenta, `mover_entre_bolsillos` = bolsillo → bolsillo): las tres son delgadas y llaman a `_mover_bolsillo`. Orden: **sesión** (E4) → **monto** (`_validar_monto`, E5) → **bolsillo(s)** (`_bolsillo_propio`: texto uuid de MI cuenta; mal formado, inexistente o ajeno = `Recurso no encontrado`) → **mismo bolsillo** (D-E6-9) → **una** `_reloj_instantanea()` → `_asentar_grupo` (plantilla `BOLSO_INGRESO` / `BOLSO_RETIRO` / `BOLSO_MOVIMIENTO` de E2; dos patas con el mismo `grupo`, `tx_id` y fecha; `contraparte_nombre` = nombre del bolsillo del otro lado, `nota` NULL). `Saldo insuficiente` lo da el libro. Devuelven `{id, fecha}`.
* **`crear_bolsillo(usuario, nombre)`** → `{id, nombre}`: nombre normalizado (recorte y colapso de espacios), 1–40 caracteres, sin caracteres de control (D-E6-8 provisional); nombres repetidos permitidos; sin tope. Una instantánea: `ultimo_cobro` = hoy del banco, `creado_en` = ahora del banco; balance 0. Es el **único** `INSERT` de E6; el dinero nunca se escribe a mano.
* **`vista_balance(usuario)`** → `{total, principal, bolsillos:[{id, nombre, saldo}]}` (`GET /bolsillos`): solo los bolsillos de mi cuenta, en orden `creado_en`/`id`, `[]` si no hay, ids como texto uuid utilizables tal cual en las otras funciones. **Una sola sentencia** (una sola foto): `principal`, `bolsillos` y `total` no pueden verse a medias de un movimiento concurrente. No calcula interés ni consulta el reloj.
* **`balance_total(cuenta)`** (interno, `STABLE`): la **única** definición del «total» (D-E6-12, **provisional hasta D6**): `cuenta.balance + Σ bolsillo.balance`. CDT y créditos se incorporarán cuando el equipo resuelva D6; hoy esas tablas no tienen filas. Es `STABLE` a propósito: una función `VOLATILE` tomaría su propia foto dentro de la sentencia.
* **Carreras:** si entre la validación y el bloqueo se borran un bolsillo o el propio usuario, el libro avisa y la función lo traduce a `Recurso no encontrado` / `Sesión inválida` (la subtransacción revierte todo; el origen no pierde dinero). En `crear_bolsillo`, la violación de FK por usuario borrado se traduce a `Sesión inválida`. Nunca llega un error no-`P0001` (el backend lo convertiría en 503).
* **Permisos:** `banco_app` (y `banco_dev` por herencia) ejecuta **exactamente 12** funciones (las 7 de E4–E5 + estas 5); `banco_lector` y `PUBLIC` ninguna; los 4 helpers, nadie salvo el dueño.

### Punto de integración con E7 (`avanzar_hasta`) — nada implementado
El punto está **marcado en el código** (`-- (E7: …)`) en `vista_balance`, `_mover_bolsillo` (cubre las 3 de movimiento) y `crear_bolsillo`; `hacer_transferencia` (E5) ya lo tenía marcado. Cómo se garantizará: (1) la operación toma `_reloj_instantanea()` **una vez** y pasa `(hoy, ahora)` a un `_avanzar_hasta(cuenta, hoy, ahora)` interno, que no vuelve a leer el reloj; (2) `_avanzar_hasta` toma primero el bloqueo de la fila de la cuenta (el mismo del libro), de modo que ningún movimiento ajeno se cuela entre el devengo y la operación; (3) E7 añadirá un escaneo del catálogo («toda función de `banco_app` que lee o mueve saldos de bolsillo llama a `_avanzar_hasta`») y una mutación que la quite de cada una. La prueba `52` ya fija hoy que E6 no define ninguna `avanzar_hasta` ni interés, y que el marcador existe en las 3 funciones.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`db\ctl.cmd test`) | **1930 aprobadas, 0 fallidas** (baseline E5: 1749; E6 aporta 181: 60 + 7 SQL, 93 + 21 de conexiones reales y concurrencia) — `evidencias/06-bolsillos.txt` |
| Ejecución desde cero | `reset` + 3 × `apply` (17 scripts cada vez): **0 errores**; 11 tablas en `public` + `audit.evento`; **61 funciones**; 16 triggers; 7 vistas; `banco_app` ejecuta exactamente 12; `v_integridad_global` ok — `evidencias/06-bolsillos-aplicacion.txt` |
| Mutaciones | **23 de 23** nuevas detectadas (M114–M136) — `evidencias/06-bolsillos-mutaciones.txt` |
| Regresión E1–E5 | verde (incluye idempotencia con el script 16, permisos, reloj, auth y transferencias) |
| Integridad | `v_integridad_global` en orden tras las 600 operaciones aleatorias contra un modelo y las de concurrencia |

Cobertura por la prioridad pedida: **(a) integridad de saldos**: conservación por cliente (cuenta + bolsillos), nunca negativo, saldo exacto y +0,01 en cada origen, 600 operaciones aleatorias contra un modelo con la vista comparada **tras cada operación** (53); **(b) atomicidad**: fallos inyectados `tx:1`/`tx:2` en las 3 operaciones (52 y reales 43 C) y corte de conexión `corte:1`/`corte:2`; **(c) concurrencia** (reales 44): doble retiro (6 × 800 con 1000: gana 1), A→B ∥ B→A más ingresos/retiros del mismo cliente (40 sesiones, sin deadlock), retiro ∥ envío de E5 desde el mismo bolsillo (gana exactamente 1), `crear_bolsillo` ∥ borrado del usuario, movimientos con cambios de reloj; **(d) lecturas consistentes de `vista_balance`**: 6 sesiones leen 1500 veces mientras 4 sesiones mueven dinero sin parar → en **todas** `total = principal + Σ saldos` y el total del cliente es constante (44 §5), más la prueba estática de que `balance_total` es `STABLE` y que la vista usa una sola sentencia (52); **(e) permisos** con roles reales por TCP (52 y 43 B); **(f) carreras por borrado** esperando el bloqueo del reloj (43 D): bolsillo destino borrado en un ingreso y en un movimiento (el origen conserva su saldo), usuario borrado en un movimiento, usuario borrado en `crear_bolsillo`; **(g) reloj**: una instantánea por operación (escaneo + conteo dinámico: 1 + 2 patas = 3 lecturas; `crear_bolsillo` 1; `vista_balance` 0) y reloj manual (`ultimo_cobro`, `creado_en` y la fecha de las patas salen del reloj del banco).

## 4. Desviaciones y límites (sin ocultar nada)

1. **Los mensajes nuevos no están en `_msg_negocio`:** esa función vive en `15_transferencias.sql` (E5, que no se modifica). `Nombre de bolsillo inválido` y `Los bolsillos de origen y destino deben ser distintos` están en `_reglas_bolsillo()`, junto con el rango del nombre (un solo punto de cambio de los valores provisionales). El diseño decía «`_reglas_bolsillo()`/`_msg_negocio`»; se eligió la primera por no tocar E5.
2. **61 funciones, no 59:** el diseño v2 las cuenta así (52 + 4 helpers + 5 públicas = 61). (El diseño v1 hablaba de 59 antes de incluir `vista_balance` y `balance_total`.)
3. **`balance_total` (D-E6-12) es provisional:** `total = cuenta + bolsillos`. No debe presentarse como la definición final de D6; cuando el equipo decida (CDT con o sin generado, deuda restando o no), solo cambia esa función. Hoy el valor coincide con cualquier resolución de D6 porque no hay CDT ni créditos.
4. **`avanzar_hasta`/interés fuera (D-E6-5):** el saldo de un bolsillo no devenga interés hasta E7; `vista_balance` muestra el saldo sin interés pendiente.
5. **Valores provisionales del equipo** (centralizados en `_reglas_bolsillo()`, **no** decisiones finales): **D-E6-8** nombre 1–40 y `Nombre de bolsillo inválido`; nombres repetidos permitidos y sin tope; **D-E6-9** mensaje de «mismo bolsillo». **Pendientes de negocio, sin implementar:** D-E6-10 (renombrar/borrar bolsillos, tope) y D-E6-11 (si los movimientos salen en el historial; D8, E10). **D-E6-12:** composición de `total` (D6).
6. **Sin idempotencia:** un doble clic = dos movimientos atómicos (como E5); nada queda negativo.
7. **La rama «usuario borrado entre la sesión y la lectura» de `vista_balance` no se puede forzar por tiempo** (la lectura no toma el reloj ni el bloqueo de la cuenta): queda como defensa sin prueba determinista. La de `crear_bolsillo` y las de movimiento sí se prueban (reales 43 D).
8. Un movimiento en curso no se cancela si el usuario es bloqueado a mitad (el estado se lee al iniciar). Superusuario: el límite ya documentado; las pruebas de permisos usan roles reales por TCP.
9. Un bolsillo con patas no se puede borrar suelto (FK del libro); solo desaparece con el borrado en cascada del usuario (E11). Las pruebas de carreras usan bolsillos **sin** patas para poder borrarlos.
10. Las pruebas que sustituyen `_ahora_real()` o inyectan fallos solo corren en `banco_test`/`banco_mut` (guardas explícitas) y terminan restaurando el estado real.
11. **Corrección en la propia prueba durante el desarrollo (no del código):** la primera versión de la prueba de concurrencia 6 de `reales/44` dejaba la cuenta en 0 y los ingresos fallaban por `Saldo insuficiente` (error del escenario, no de la función); se financió la cuenta. Las mutaciones se explican en §5.

## 5. Mutaciones

Resultado y detalle en `docs/db/evidencias/06-bolsillos-mutaciones.txt`. Las M114–M136 rompen a propósito: sesión sin validar en la vista y en los movimientos, `total` sin bolsillos, bolsillos sin filtro de cuenta (se verían los de otros), `null` en vez de `[]`, `balance_total` `VOLATILE`, bolsillo ajeno aceptado, dos instantáneas, `now()` en las patas, contraparte sin cruzar, «mismo bolsillo» sin comprobar, traducciones de carrera quitadas, nombre sin normalizar, límite del nombre cambiado, FK sin traducir, `current_date` en `ultimo_cobro`, plantillas o argumentos invertidos, y los permisos (helper concedido a `banco_app`, `EXECUTE` quitado a `vista_balance`, lector con `crear_bolsillo`, pérdida de `SECURITY DEFINER`). **Matices honestos:** (a) M118 (`balance_total` `VOLATILE`) la detecta la comprobación estática de `52` (`provolatile = 's'`); no se ejecutó la prueba dinámica de lecturas (`reales/44` §5) contra esa mutación, así que esa prueba demuestra la consistencia del código real pero no se comprobó que por sí sola detecte la lectura rota; (b) M132–M135 las detecta `52` por un efecto indirecto (un `Saldo insuficiente` inesperado o la lista blanca de `v_integridad_defensas`, que forma parte de «integridad global»), no por una aserción específica; (c) la detección por `52` es inmediata, por eso las mutaciones de carrera (M125, M126, M129) se confirman con `reales/43`. **M01–M113 no se re-ejecutaron** (E6 solo toca `09_integridad.sql`, cuya lista blanca cubren los controles de E4–E5, M86–M89 y las pruebas `10`, `50`, `52` y reales `41`/`43`).

## 6. Verifícalo en pgAdmin
Conexión «Banco — administración (postgres)», base `banco`, Query Tool → *Open File* → `docs/db/evidencias/06-pgadmin-demo.sql` → F5. Todo va en `BEGIN … ROLLBACK`; los resultados salen en la pestaña **Messages** (`docs/db/evidencias/06-pgadmin-demo-salida.txt` tiene la salida de referencia). Consultas sueltas útiles:

```sql
SELECT proname, prosecdef, provolatile, proacl FROM pg_proc WHERE proname IN ('crear_bolsillo','mover_a_bolsillo','retirar_de_bolsillo','mover_entre_bolsillos','vista_balance','balance_total','_mover_bolsillo','_bolsillo_propio','_reglas_bolsillo');
SELECT control, ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta%';
SELECT obj_description('public.vista_balance(uuid)'::regprocedure, 'pg_proc');
```

## 7. Checklist de auditoría
- [x] Todo movimiento por `_asentar_grupo`; el único `INSERT` es el de `crear_bolsillo` (balance 0); ningún `UPDATE` de saldos (escaneo + mutación)
- [x] Una `_reloj_instantanea()` por movimiento y por creación; `vista_balance` no toca el reloj
- [x] `balance_total` única definición del total, interna y `STABLE`; `vista_balance` en una sola sentencia
- [x] Mensajes exactos del contrato §6 y orden de validación (monto → bolsillo(s) → mismo bolsillo → saldo)
- [x] Atomicidad (fallos en cada pata y corte de conexión) y carreras traducidas sin rastro
- [x] Conservación del dinero por cliente, nadie negativo, concurrencia sin deadlocks, lecturas consistentes
- [x] `banco_app` ejecuta exactamente 12 funciones; helpers internos sin acceso; lector sin acceso
- [x] Provisionales (D-E6-8/9/12) presentados como tales; pendientes (D-E6-10/11) sin implementar
- [x] Punto de integración de `avanzar_hasta` documentado; sin interés ni E7
- [x] Sin commits; `front/`, backend y E5 intactos; E7 no iniciada
