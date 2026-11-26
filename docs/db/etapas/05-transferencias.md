# Etapa 5 — Transferencias · paquete de entrega

**Estado (2026-11-23):** implementada, probada y **APROBADA** por el responsable de BD tras su auditoría (sin cambios de código solicitados). Sin commits; `front/` y backend intactos; E6 no iniciada. Diseño aprobado: `05-transferencias-diseno.md` (D-E5-1..7). Resumen para el backend: `05-resumen-para-juan.md`.

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| `nombre_destinatario`, `hacer_transferencia` + helpers `_msg_negocio`, `_validar_monto`, `_reglas_transferencia` | `db/sql/15_transferencias.sql` (idempotente, como `banco_owner`, `SECURITY DEFINER`) |
| Lista blanca de `banco_app`: 5 → **7** funciones | `db/sql/09_integridad.sql` (`v_integridad_defensas`) |
| Pruebas nuevas | `db/tests/50_transferencias.test.sql` (53), `51_transferencias_aleatorio.test.sql` (7), `reales/41_transferencias_conexiones.sh` (69), `reales/42_transferencias_concurrencia.sh` (16) |
| Pruebas adaptadas (solo inventario) | `03_schema` (52 funciones), `10_libro_triggers` (51 de `banco_owner`, definer y lista blanca de 7), `09_idempotencia` (re-aplica también el 15) |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M92–M113** (22 nuevas) |
| Evidencias | `docs/db/evidencias/05-transferencias*.txt`, `05-pgadmin-demo.sql` y su salida |

## 2. Cómo funciona (resumen)

`hacer_transferencia(p_usuario_id uuid, p_numero_destino text, p_monto numeric, p_nota text, p_bolsillo_origen text) → jsonb {id, fecha}`. Orden: **sesión** (E4) → **monto** → **destino** (10 dígitos, existe) → **autoenvío** → **bolsillo** (texto uuid, debe ser de mi cuenta) → **nota** → **una** `_reloj_instantanea()` → `_asentar_grupo` (plantilla `ENVIO_CUENTA` o `ENVIO_BOLSILLO`: ENVIO + RECIBO con la misma fecha y grupo, nota y contrapartes cruzadas con nombre completo). Todo el dinero lo mueve el libro (E2: bloqueo ordenado de cuentas, cuadre, saldo no negativo); la función **no** escribe saldos ni patas por su cuenta.

* **Carreras:** si entre la validación y el bloqueo se borran el destino, el bolsillo o el propio emisor, el libro avisa y la función lo traduce a `Cuenta no encontrada` / `Recurso no encontrado` / `Sesión inválida`; la subtransacción revierte todo (nunca un error no-`P0001`, que el backend convertiría en 503).
* `nombre_destinatario(p_usuario_id, p_numero_cuenta) → {nombre}`: exige sesión viva; no toca reloj ni libro.
* Helpers reutilizables por E6–E9: `_msg_negocio(clave)` (mensajes de negocio en un solo lugar), `_validar_monto(numeric)` (NULL, NaN, ±∞, ≤ 0, más de 2 decimales o `> parametro.monto_maximo` → `Monto inválido`), `_reglas_transferencia()` (`nota_max = 140`).
* Permisos: `banco_app` (y `banco_dev` por herencia) ejecuta **solo** las 2 públicas; `banco_lector` y `PUBLIC` ninguna; los 3 helpers nadie salvo el dueño.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`db\ctl.cmd test`) | **1749 aprobadas, 0 fallidas** (baseline E4: 1604; E5 aporta 145: 53 + 7 SQL, 69 + 16 de conexiones reales y concurrencia) |
| Ejecución desde cero | `reset` + 3 × `apply`: **0 errores**; 11 tablas en `public` + `audit.evento`; **52 funciones**; 16 triggers; 7 vistas (`evidencias/05-transferencias-aplicacion.txt`) |
| Mutaciones | **22 de 22** nuevas detectadas (M92–M113) + **6 de 6** de permisos de E4 re-ejecutadas como regresión (M86–M91); M01–M85 no re-ejecutadas (ver §4.9) |
| Regresión E1–E4 | verde (incluye idempotencia con el script 15, permisos, reloj y auth) |
| Integridad | `v_integridad_global` en orden tras las pruebas aleatorias (600 operaciones contra un modelo) y las de concurrencia |

Cobertura por prioridad pedida: **(a) validaciones y mensajes** exactos y su orden (50, 51, reales 41); **(b) cuenta y bolsillo** (50, 41, 42); **(c) atomicidad en ambas patas** con fallos inyectados `tx:1`/`tx:2` (incl. tras el débito) y corte de conexión `corte:1`/`corte:2` (reales 41 C); **(d) carreras por borrado** del destino, del bolsillo y del emisor, esperando el bloqueo del reloj (reales 41 D); **(e) conservación y no-negativos** (51, 42); **(f) permisos con roles reales por TCP** (50, 41 B); **(g) concurrencia**: 6 × 800 con saldo 1000 → gana 1, cruzadas A↔B sin deadlock, muchos→uno con saldo exacto, cuenta vs bolsillo, y envíos con cambios de reloj (42); **(h) reloj**: una sola instantánea (escaneo de catálogo + conteo dinámico de lecturas: 1 + 2 patas = 3) y ambas patas con la misma fecha (50).

## 4. Desviaciones y límites (sin ocultar nada)

1. **52 funciones, no 51:** se añadió el helper `_reglas_transferencia()` para centralizar la constante provisional de la nota (D-E5-8).
2. **Emisor borrado en carrera → `Sesión inválida`:** la prueba de carreras reveló que el texto interno del libro («Libro mayor: …») habría llegado al cliente; se añadió esa traducción (no estaba en el diseño). Un envío ya en curso tampoco se cancela si el emisor es bloqueado a mitad (se lee el estado al iniciar; instantes).
3. **`avanzar_hasta` diferido a E7 (D-E5-5):** el punto está marcado en el código; el saldo de un bolsillo todavía no devenga interés antes de enviar.
4. **Valores provisionales del equipo** (centralizados, **no** son decisiones finales): **D-E5-8** nota máx. 140 y mensaje `Nota inválida`; **D-E5-9** una cuenta bloqueada **puede recibir** (negocio pendiente; un solo punto de cambio); **D-E5-10** `nombre_destinatario` lleva `p_usuario_id` y exige sesión (coordinar con Juan, ver `05-resumen-para-juan.md`). **D-E5-11:** sin límites, comisiones ni idempotencia (no están en el contrato): un doble clic = dos envíos atómicos.
5. **Enumeración:** `nombre_destinatario` revela el nombre completo a cualquier cliente con sesión que conozca un número de cuenta (spec 7.3); el límite de tasa es del backend.
6. **Superusuario:** el límite ya documentado (puede saltarse triggers y permisos); las pruebas de permisos usan roles reales por TCP, no `SET ROLE` desde superusuario, donde importa.
7. Las pruebas que sustituyen `_ahora_real()` o inyectan fallos solo corren en `banco_test`/`banco_mut` (guardas explícitas) y terminan restaurando el estado real.
8. **Corrección de una prueba de E4 (no del código):** la suite completa mostró un fallo intermitente de `42_auth_ingresos` (aserción «ningún ingreso fechado después de la fecha del banco» con `<`). El último tramo de ingresos termina en `ahora − margen`, así que a ciertas horas del día (la prueba falló a las 22:50 de Bogotá, ~5 %) un ingreso cae **el mismo día, horas antes**, que el contrato y el libro permiten. Se cambió a `<=` (día posterior = error) y se aclaró la etiqueta. Sin cambios en `14_auth_funciones.sql`. Repetida la suite completa: verde.
9. **Mutaciones:** se ejecutaron las 22 nuevas (M92–M113, con las pruebas de E5 al frente del orden de detección) y, como regresión de la lista blanca ampliada a 7, las de permisos de E4 (M86–M91; ver `05-transferencias-mutaciones-regresion.txt`). Las M01–M85 **no** se re-ejecutaron: E5 no toca sus scripts (solo `09_integridad.sql`, cuya lista blanca cubren M86–M89 y las pruebas 10/45/50/reales 39 y 41).

## 5. Verifícalo en pgAdmin
Conexión «Banco — administración (postgres)», base `banco`, Query Tool → *Open File* → `docs/db/evidencias/05-pgadmin-demo.sql` → F5. Todo va en `BEGIN … ROLLBACK`; los resultados salen en la pestaña **Messages** (`docs/db/evidencias/05-pgadmin-demo-salida.txt` tiene la salida de referencia). Consultas sueltas útiles:

```sql
SELECT proname, prosecdef, proacl FROM pg_proc WHERE proname IN ('hacer_transferencia','nombre_destinatario','_validar_monto','_msg_negocio','_reglas_transferencia');
SELECT control, ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta%';
SELECT obj_description('public.hacer_transferencia(uuid,text,numeric,text,text)'::regprocedure, 'pg_proc');
```

## 6. Checklist de auditoría
- [x] Todo movimiento por `_asentar_grupo`; ningún `INSERT`/`UPDATE` de saldos en el código (escaneo + mutación)
- [x] Una `_reloj_instantanea()` por transferencia; ambas patas con la misma fecha
- [x] Mensajes exactos del contrato §6 y orden de validación (monto → destino → autoenvío → bolsillo → nota → saldo)
- [x] Atomicidad (fallos en cada pata y corte de conexión) y carreras traducidas sin rastro
- [x] Conservación del dinero, nadie negativo, concurrencia sin deadlocks
- [x] `banco_app` ejecuta exactamente 7 funciones; helpers internos sin acceso; lector sin acceso
- [x] D-E5-8/9/10 presentadas como **provisionales**; coordinación con Juan documentada
- [x] Sin commits; `front/` y backend intactos; E6 no iniciada
