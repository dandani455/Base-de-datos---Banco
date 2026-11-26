# Etapa 11 — Administración (usuarios, ajuste de balance, reloj y tasas) · paquete de entrega

**Estado (2026-11-25): IMPLEMENTADA; AUDITORÍA TÉCNICA APROBADA; PENDIENTE DE TU APROBACIÓN FINAL tras el cierre de §7.** Diseño v1.1 aprobado (`11-admin-diseno.md`) y seguido sin cambiar el alcance ni el plan de pruebas de §7. **D-E11-D7a (mora NULL ↔ 0) y D-E11-D7b (efecto retroactivo del cambio de la tasa de mora sobre la mora ya vencida) siguen siendo decisiones provisionales / NO aprobadas por el equipo**: se implementó solo la propuesta centralizada de D7a y **ninguna lógica sobre D7b** (§4). Sin commits; `front/` intacto; el backend **no se integró ni se modificó en ninguna rama** (el borrador de `origin/main` es temporal y no es fuente de autoridad; el parche de una línea queda solo como referencia descartable, §5.1 y §8). **E12 no iniciada.**

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| 12 públicas `admin_*` (todas con `p_admin_id` primero) y 4 internas (`_reglas_admin`, `_parse_tasa`, `_cliente_objetivo`, `_auditar_admin`) | `db/sql/24_admin.sql` (idempotente, transaccional, comentado; **no modifica ningún objeto de E1–E10**) |
| Integración (solo los puntos del diseño) | `09_integridad.sql` (lista blanca de `banco_app` 26 → **38** y su texto), y los inventarios de las pruebas anteriores (§3) |
| Pruebas nuevas | `68_admin_usuarios`, `69_admin_reloj_tasas`, `70_admin_aleatorio`, `reales/53_admin_conexiones`, `reales/54_admin_concurrencia` (conteos en §3) |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M341–M400** (§6) |
| Parche del backend (referencia descartable; NO integrado) | [`11-parche-backend-usuarios.patch`](11-parche-backend-usuarios.patch) (§5.1 y §8) |
| Resumen para el backend + tabla maestra | `11-resumen-para-juan.md` (y la fila `/admin/*` de `10-resumen-para-juan.md`) |
| Evidencias | `docs/db/evidencias/11-admin*.txt`, `11-pgadmin-demo.sql` y su salida, `git_status_e11.txt` |

## 2. Cómo funciona

```
admin_*(p_admin_id, …)
 _validar_admin (E4: Acceso denegado / mensaje de bloqueo)  ← SIEMPRE lo primero, antes de leer o validar nada
 → parámetros (texto: ids, tasas) → objetivo (_cliente_objetivo: solo CLIENTES)
 → [detalle y ajuste] UNA _reloj_instantanea() → bloqueo de la cuenta → motor (_avanzar_hasta) → una sola sentencia / el libro (_asentar_grupo)
 → acción → _auditar_admin (UN evento, actor = el admin) → respuesta jsonb
```

| Función | Qué hace (resumen) |
|---|---|
| `admin_listar_usuarios(admin, busqueda)` | Solo CLIENTES (un ADMIN no tiene cuenta); `ILIKE` sin tildes por nombre, cédula, correo o número de cuenta; comodines del usuario literales; máx. 200; no corre el motor. |
| `admin_detalle_usuario(admin, id text)` | Datos + `balance {total, principal, bolsillos, cdts activos, creditos activos}` + `historial` (50, `_json_transacciones` de E10). Corre el motor sobre el consultado y lee en una sola sentencia. |
| `admin_bloquear` / `admin_desbloquear` | Cambian `usuario.estado` de un CLIENTE bajo bloqueo de su fila; idempotentes (sin cambio no hay `UPDATE` ni evento); rigen desde la siguiente petición. |
| `admin_borrar_usuario` | Bloquea la cuenta, escribe `USUARIO_BORRADO` y borra con la cascada de E1 (`CUENTA_BORRADA` de E2 conserva los saldos y la deuda, atribuido al admin). |
| `admin_ajustar_balance(admin, usuario, monto, nota)` | Monto **con signo**; destino uuid / username / número de cuenta; `AJUSTE_ADMIN_POS/NEG` por `_asentar_grupo`; instantánea → bloqueo → motor → libro → evento. |
| `admin_get_reloj` / `admin_set_reloj` | Envuelven `_reloj_vista` / `_reloj_actualizar` de E3 (la fecha se ignora en modo real; `RELOJ_CAMBIO` atribuido al admin). |
| `admin_get_tasas` | `{cdts, creditos, mora}`; la mora sin valor se lee **0** (D-E11-D7a, provisional). |
| `admin_set_tasa_cdt` / `_credito` / `_mora` | Tasa como **texto** validada por `_parse_tasa`; id inexistente = `Recurso no encontrado`; `pg_advisory_xact_lock` común; evento `TASA_CAMBIO` solo si el valor cambia. Solo afectan lo que se cree después (la tasa se copia al crear). |

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`ctl.sh test --evidence 11-admin`) | **3036 aprobadas, 0 fallidas** (E10 cerró en 2827: **+209**, 0 menos; las adaptadas siguen verdes). El estimado del diseño era ≈ +195. |
| Pruebas nuevas (aserciones que cuenta el runner) | `68_admin_usuarios` **71**, `69_admin_reloj_tasas` **60**, `70_admin_aleatorio` **8**, `reales/53_admin_conexiones` **53**, `reales/54_admin_concurrencia` **17** (plan de §7: ≈ 75 / 55 / 8 / 35 / 15) |
| `reset` + 3 × `apply` desde cero | **sin errores** (`11-admin-aplicacion.txt`; **25 archivos** por pasada): 11 tablas + `audit.evento`, **125 funciones**, **21 triggers** (ninguno nuevo), **9 vistas**; `banco_app` ejecuta exactamente **38** (las 12 `admin_*` y ninguna de las 4 internas); `v_integridad_global.ok` y 0 defensas fallidas; `banco` queda **limpia** (0 usuarios, reloj real, `tasa_mora_anual` NULL, sin esquema `tests`) |
| Mutaciones nuevas M341–M400 (60) | **59 detectadas + 1 equivalente declarada (M356)** (`11-admin-mutaciones.txt`). La primera corrida dejó 2 sin detectar (M355 y M373): se corrigieron (§6) y se repitieron |
| Regresión (E2–E10: libro, auditoría del borrado, reloj, integridad, motor, `vista_cdts`, permisos y plantillas; 55) | **55 de 55 detectadas** (`11-admin-mutaciones-regresion.txt`) |
| Permisos (conexiones reales por TCP, sin superusuario) | `reales/53` B1–B8: un cliente real con su `usuario_id` llamando a **cada una de las 12** = `Acceso denegado`, admin bloqueado = mensaje de bloqueo, uuid desconocido = `Acceso denegado`, `banco_lector` y los helpers sin `EXECUTE`, ninguna escritura directa de `usuario`/tasas/reloj/`audit.evento` |
| Concurrencia (conexiones reales) | `reales/54`: 30 ajustes simultáneos al mismo usuario (suma exacta), ajustes + detalles + transferencias cruzadas sin deadlock, **2 administradores guardando las 3 tasas a la vez en orden opuesto (5 rondas: siempre un formulario completo)**, bloquear ∥ operar, **borrar ∥ operaciones del usuario**, lectores del detalle ∥ escritores |
| Parche del backend (§5.1, §8) | comprobado una vez sobre una copia temporal fuera del repositorio (ya descartada): `vitest run` 46 pasan + 1 omitida y `tsc --noEmit` sin errores. **No integrado en ninguna rama.** |
| Demo de pgAdmin | `11-pgadmin-demo.sql` + salida real `11-pgadmin-demo-salida.txt` (todo en `BEGIN … ROLLBACK`; `banco` queda limpia) |

Qué cubre cada archivo nuevo:
* **68** — lista (solo clientes, 4 criterios, sin tildes, comodines literales, orden, tope de 200, `[]`, sin motor ni escritura); detalle (forma de `types.ts`, total = `vista_balance`, historial = `vista_historial`, **corre el motor sobre el consultado**: cierra el CDT y devenga al mirarlo; solo CDT/créditos activos; tope de 50; fechas `-05:00` con la sesión en UTC; ids inválidos); bloquear/desbloquear (efecto inmediato, idempotencia, auditoría, solo clientes); **ajuste** (3 referencias, signo, `Saldo insuficiente`, `Monto inválido`, nota, motor antes de escribir, eventos, **falla inyectada en cada pata y en la auditoría**); **borrado** (0 filas en 7 tablas, referido con `referido_por` NULL, contraparte del tercero intacta, `USUARIO_BORRADO` + `CUENTA_BORRADA` con el admin como actor, conservación, **falla inyectada en la cascada y en la auditoría**).
* **69** — reloj (forma del contrato, retroceso, fechas inválidas, la fecha se ignora en modo real, atribución); `_parse_tasa` (matriz de válidos e inválidos); las 3 tasas (formas, eventos, mismo valor sin evento, mora 0 ↔ NULL, ids inválidos, orden de validación, advisory lock); **lo ya creado no cambia**; **la secuencia `BEGIN … ROLLBACK/COMMIT` del backend**; **control de acceso de las 12** (cliente, desconocido, NULL, admin bloqueado, sin efectos), permisos y catálogo (`_validar_admin` primero, una sola vía de auditoría, sin reloj suelto, orden de bloqueo/motor/libro/evento).
* **70** — 130 operaciones aleatorias mezclando admin y clientes: todas terminan en OK o en un mensaje de negocio; cada acción con efecto dejó su evento; sin filas colgando; `v_integridad_global.ok` con los borrados incluidos.

**Pruebas anteriores adaptadas (solo inventarios y lo que cambia por E11; ninguna se eliminó):** `03_schema` y `10_libro_triggers` (109 → **125** funciones, lista blanca 26 → **38**, SECURITY DEFINER +12, 124 de `banco_owner`), `52`, `55`, `65`, `reales/45`, `47`, `49` (lista blanca 38), `54` (el catálogo clasifica las 12: **19 devengan**, +10 exentas), `67` (A9 cubre solo las 26 funciones de cliente), `09_idempotencia` (reaplica también `24_admin.sql`).

## 4. Decisiones aprobadas y cómo se reflejan

| ID | Cómo quedó |
|---|---|
| D-E11-1 | 12 públicas + 4 internas + `24_admin.sql`; Control (`admin_esquema`, `admin_tabla`) queda en **E12**. |
| D-E11-2 | Todo sobre CLIENTES; ADMIN / uno mismo / inexistente / mal formado / vacío / NULL = `Recurso no encontrado`; `_validar_admin` **primero**; bloquear/desbloquear idempotentes; nombres del backend. |
| D-E11-3 | Sin `trg_usuario_estado` (ni ningún trigger nuevo: siguen **21**). |
| D-E11-4 | Auditoría explícita con `_auditar_admin` (1 evento por acción con efecto) + `banco.actor`; sin `trg_auditar` genérico. |
| D-E11-5 | Búsqueda `ILIKE` + `unaccent` en los 4 campos, comodines escapados, máx. 200, **sin GIN**. |
| D-E11-6 | Ajuste con referencia flexible, monto con signo, motor antes de escribir, `Saldo insuficiente` del libro, nota ≤ 140 con el `Nota inválida` de E5. |
| D-E11-7 (A) | **3 funciones de tasa** (contrato + backend) con `p_tasa text`, `_parse_tasa`, advisory lock común y evento por cambio. La atomicidad del formulario completo la da `db.tx` del backend (la prueba reproduce su secuencia `BEGIN … ROLLBACK/COMMIT` sobre una conexión real). |
| D-E11-8 | `admin_detalle_usuario` y `admin_ajustar_balance` devengan (catálogo de `54`: **19** devengan, **10** exentas nuevas). |
| **D-E11-D7a (equipo, provisional)** | La mora sin valor se **lee 0** y guardar **0 = sin mora** (se guarda NULL): centralizado en `_parse_tasa(…, permite_cero)` y `admin_get_tasas`. **No es una decisión financiera aprobada.** |
| **D-E11-D7b (equipo, NO decidido)** | La mora de E9 es *derivada*: `admin_set_tasa_mora` **no copia** la tasa a ningún crédito, así que cambiarla cambia también la mora de las cuotas **ya vencidas**. E11 **no agrega ninguna lógica** sobre esto y las pruebas **no lo fijan como comportamiento aprobado**. **Aprobar E11 no equivale a aprobar este efecto.** |
| D13 / D10 | Mensaje nuevo `Tasa inválida` (provisional, en `_reglas_admin()`); firmas no literales del contrato (nombres del backend, ids como texto, `p_tasa` como texto, referencia flexible) provisionales hasta que Juan confirme. |
| P-DEMO-1/2/3, D6, D8 | **Sin tocar** (no se limita a un único adelanto del reloj; el total y el historial del detalle usan las reglas provisionales de E6/E10). |

## 5. Desviaciones respecto al diseño y límites (sin ocultar nada)

1. **El backend NO se integró ni se modificó en ninguna rama** (decisión del responsable, 2026-11-25: el desarrollo del backend definitivo aún no empieza). **El backend de `origin/main` (commit `9062cf0`) es un borrador temporal y NO es fuente de autoridad** para E11 ni para las etapas siguientes: las decisiones salen del contrato, de `types.ts` y de la BD terminada. El parche [`11-parche-backend-usuarios.patch`](11-parche-backend-usuarios.patch) se conserva **solo como referencia descartable** (ver §8). Se comprobó una vez, en una copia temporal fuera del repositorio (ya descartada), que aplica y que `vitest` (46 + 1 omitida) y `tsc` pasan; **no se probó ningún backend contra esta BD** y sus demás incompatibilidades quedan fuera de alcance.
2. **El mensaje `Tasa inválida` vive en `_reglas_admin()` y no en `_msg_negocio`** (el diseño decía `_msg_negocio`): esa función es de E5 y E5 no se modifica; es el mismo criterio que E6 (`_reglas_bolsillo`). Sigue siendo provisional (D13) y centralizado.
3. **Eventos solo con cambio real:** bloquear/desbloquear idempotentes y las tasas con el mismo valor no escriben evento (el diseño decía «1 evento por acción que cambia algo»; el front reenvía todo el formulario al guardar y se habría llenado la auditoría de ruido).
4. **`admin_bloquear` y `admin_desbloquear` duplican su cuerpo** (≈ 20 líneas) en vez de compartir una interna: así se mantienen exactamente **4 internas / 125 funciones** como se aprobó.
5. **`admin_borrar_usuario` escribe `USUARIO_BORRADO` ANTES de borrar** (misma transacción): hace falta fijar `banco.actor` antes de que el trigger de E2 escriba `CUENTA_BORRADA`. Si el borrado falla, el evento se revierte (probado con falla inyectada).
6. **Atribución del reloj:** el disparador de E3 solo guarda `actor_username` (no `actor_id`); `RELOJ_CAMBIO` queda atribuido por nombre. Los eventos de E11 sí llevan `actor_id` y `actor_username`.
7. **Búsqueda sin `username`:** los 4 criterios del contrato son nombre, cédula, correo y cuenta; el front muestra el username en la tabla pero buscar por él no encuentra nada (no se inventó el criterio).
8. **Defensa en profundidad redundante:** `_cliente_objetivo` exige rol CLIENTE y además cada función lo vuelve a comprobar (la fila bloqueada, el `DELETE`, la existencia de la cuenta). Por eso quitar solo una capa no es observable (M355 rompe las dos; M356, el filtro de rol de la lista, es **equivalente** porque un ADMIN no tiene cuenta y la lista hace `JOIN`).
9. **Más pruebas y mutaciones que el estimado:** +209 aserciones (≈ +195) y **60 mutaciones** (≈ 32): se mutó cada una de las 12 funciones por separado en el control de acceso (12) y se cubrieron los permisos con conexiones reales.
10. **Límites de las pruebas:** las carreras se provocan con esperas de 2,5 s sobre el bloqueo del reloj o de la cuenta (deterministas, no exhaustivas); la atomicidad del formulario completo de tasas se prueba **reproduciendo** la secuencia de `db.tx` sobre una conexión real, no ejecutando el backend; `precision.test.mjs` (E10) no se volvió a correr (E11 no cambia ninguna salida numérica de E10).
11. **Límites de diseño (ya documentados):** la atomicidad del formulario de tasas depende de que el backend use UNA transacción; consultar a un usuario como admin puede cobrarle una cuota o cerrar su CDT (motor perezoso); los eventos de auditoría son atribución, no un control de seguridad (un superusuario puede saltarse las funciones).

## 6. Mutaciones

Bloque **M341–M400** (60): **`_validar_admin` ausente en cada una de las 12 funciones** (12), validación tardía, admin bloqueado admitido, alcance (`_cliente_objetivo` y capas redundantes), búsqueda (sin cuenta, sin `unaccent`, comodines sin escapar, sin tope), detalle (CDT cerrados, créditos pagados, sin motor, historial de otra cuenta, total sin `balance_total`, doble instantánea), bloquear (invertido, sin idempotencia, evento con otro nombre), auditoría (sin actor, sin `banco.actor`), borrado (evento, sin bloqueo de cuenta, `referido_por` sin `SET NULL`, cascada rota), ajuste (signo invertido, sin motor, sin bloqueo, nota ilimitada, evento, sin validar monto, referencia solo uuid), reloj (sin atribución, fecha ignorada), tasas (sin tope, `0` fuera de la mora, decimales, id desconocido ignorado, sin advisory lock ×2, evento, mora 0 sin NULL, mora NULL en la lectura, evento sin cambio) y 6 cambios de permisos / `SECURITY INVOKER` / privilegios de tabla.

**Resultado: 59 detectadas + 1 equivalente (M356)** (`11-admin-mutaciones.txt`). **Dos huecos hallados y corregidos (como en E7–E10):**
* **M373** (el borrado sin bloquear la cuenta) no se detectaba: el catálogo de `69`/H6 usaba `strpos(bloquear) < strpos(auditar)`, que es **verdadero cuando la llamada desaparece** (`strpos = 0`). Ahora exige también `> 0`.
* **M355** (admin aceptado como objetivo) era no observable por la defensa en profundidad (§5.8): se rehízo rompiendo las dos capas de `admin_bloquear` a la vez, y quedó detectada por `68`/C8.

**Regresión** (`11-admin-mutaciones-regresion.txt`): las 46 de la regresión de E10 más M08, M09, M20 (auditoría del borrado) y M25–M28, M30, M31 (reloj): **55 de 55**.

## 7. Cierre de auditoría (2026-11-25)

Auditoría técnica **aprobada** sin defectos funcionales ni de seguridad. Se hizo **solo** esto:
* **Comentario desfasado corregido:** `COMMENT ON VIEW v_integridad_defensas` (`09_integridad.sql`) decía «E4-E10 … 26 funciones»; ahora dice **«E4-E11: banco_app ejecuta exactamente las 38 funciones públicas (… y las 12 `admin_*` de administración)»**. Es solo un comentario (ninguna lógica cambia). Se reaplicó `09_integridad.sql` a `banco` y se verificó el texto y que las defensas siguen en orden (`11-admin-cierre-auditoria.txt`). No se repitió la suite completa, como se pidió; el repaso de `26 | E4-E10` en `db/sql` ya no encuentra nada desfasado.
* **Parche del backend: conservado, no integrado** (§8).

## 8. Parche del backend: referencia descartable (pendiente para la etapa de backend)

| | |
|---|---|
| Archivo | [`11-parche-backend-usuarios.patch`](11-parche-backend-usuarios.patch) (2 líneas) |
| **Problema que resuelve** | El `GET /admin/usuarios` del borrador de backend lee `admin_listar_usuarios` con `db.call(...)` (espera un *conjunto de filas*, como pedía el plan), pero la BD devuelve **`jsonb`** (decisión D3 de todo el proyecto) en una sola celda; sin el cambio, la respuesta sería `[{"admin_listar_usuarios":[…]}]` en vez de la lista. |
| Cuándo aplicarlo | **Nunca sobre el borrador de `origin/main`.** Solo se tiene en cuenta cuando se **desarrolle el backend definitivo**: allí hay que leer el resultado de **todas** las funciones de la BD como `jsonb` (no solo esta). |
| Estado | Referencia **descartable**: no está en ninguna rama, no hay commits. Cuando llegue el backend definitivo se **vuelve a contrastar todo** contra el contrato, `types.ts` y la BD terminada, sin dar por buena ninguna suposición del borrador. |

## 9. Verifícalo en pgAdmin

1. Conexión **«Banco — administración (postgres)»** → base `banco` → Query Tool → *Open File* → [11-pgadmin-demo.sql](../evidencias/11-pgadmin-demo.sql) → **F5** (todo va en `BEGIN … ROLLBACK`; los resultados salen como `NOTICE` en *Messages*). Salida de referencia: [11-pgadmin-demo-salida.txt](../evidencias/11-pgadmin-demo-salida.txt). Recorre: la lista y sus búsquedas, el detalle de un cliente con productos, ajustes por uuid / username / número de cuenta (y sus rechazos), bloqueo y desbloqueo (el efecto en la siguiente petición), el reloj (atribuido al admin), las tasas (incluida la secuencia del backend que se revierte y la mora 0), el borrado con su auditoría y el historial del tercero, el control de acceso (cliente, admin bloqueado, desconocido), permisos e integridad.
2. Consultas sueltas (superusuario; no escriben):
   * `SELECT accion, actor_username, entidad, entidad_id, antes, despues FROM audit.evento ORDER BY orden DESC LIMIT 20;` — la auditoría de las acciones de administración.
   * `SELECT public._reglas_admin();` — tope de la lista, nota, tasas y el mensaje `Tasa inválida` en un solo lugar.
   * `SELECT proname, prosecdef, has_function_privilege('banco_app', oid, 'EXECUTE') AS app FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'admin\_%' ORDER BY 1;` — las 12 públicas.
   * `SELECT control, ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta%';` — la lista blanca de 38.
