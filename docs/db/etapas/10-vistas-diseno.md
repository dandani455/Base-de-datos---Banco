# Etapa 10 — Vistas del contrato (dashboard e historial) · DISEÑO TÉCNICO v1 (compacto, para aprobación)

**Estado (2026-11-24): DISEÑO v1 APROBADO (D-E10-1 a D-E10-8; D-E10-9 con el ajuste de alcance de la precisión); IMPLEMENTADO → paquete de entrega en `10-vistas.md` (pendiente de la auditoría; las desviaciones técnicas están en su §5).** E9 aprobada y cerrada. No se ha tocado `db/sql`, ni pruebas, ni `front/`, ni backend; sin commits; E11 no iniciada. Las cifras de §3 salen de un experimento de solo lectura en `banco` dentro de una transacción revertida (nada quedó escrito).
**Fuentes releídas completas para este diseño:** contrato PDF 2026-11-18 (§1–§8), `front/src/api/types.ts`, `client.ts`, `format.ts`, `Dashboard.tsx`, `Balance.tsx`, `Cdts.tsx`, `TransaccionList.tsx`, `mock/server.mjs`; spec §5–§8, §12 y §15; plan (Tasks 6–9); el diseño consolidado v3 (§B.2–B.3, C.4, F.1: *E10 = «v_* + vista_* en jsonb; precision.test.mjs»*, bloqueada por D6 y D8) y los paquetes y decisiones de E1–E9 (en especial D-E6-11/12, D-E7-5/6, D-E8-4/5, D-E9-3/12, el catálogo de `54_devengo` y las lecciones de orden por `orden`).
**Reutiliza:** `_validar_cliente`, `_reloj_instantanea` + `_avanzar_hasta` (un solo patrón de E6/E7/E8/E9), `balance_total` (única definición del «total»), `_proxima_cuota` (E9 la dejó para esto), `_interes_corriendo` (E8), `_msg_auth('sesion')`, `assert_json_shape`.

## 1. Alcance

| Entra en E10 | No entra |
|---|---|
| **`vista_dashboard(p_usuario_id)`** y **`vista_historial(p_usuario_id, p_limite)`** (las dos únicas funciones de cliente del contrato que faltan); **`v_transaccion_usuario`** (la regla de qué fila ve el usuario por cada operación del libro, una sola vez); **conformidad con el contrato** de las 24 funciones ya hechas + las 2 nuevas (nombres de campo, tipos, fechas, dinero como número, `[]`, mensajes §6); `precision.test.mjs` (D.8, D3 aprobada); la tabla maestra endpoint → función para Juan (pedida por el contrato §7.6). | Admin (E11: `admin_detalle_usuario` **reutilizará** el formateador de historial de E10), `admin_esquema/tabla` (E12), mantenimiento (E13), seed (E14). Ningún cambio de front ni backend. Ninguna fórmula financiera nueva. |

Qué falta realmente, contrato §3 contra lo ya implementado: **todo está cubierto salvo `GET /dashboard` y `GET /transacciones`**. Verificado endpoint por endpoint: registro/login/`/yo`/`/perfil` (E4), `/bolsillos` y sus 4 operaciones (E6, `vista_balance`), `/destinatario` y `/envios` (E5), `/cdts*` (E7), `/creditos*` y `/abono` (E8–E9). Pagar cuota y descuento no tienen endpoint en el contrato (E9, D10).

## 2. Qué dicen las fuentes y qué hallé al contrastarlas

| Tema | Definido | Resolución en E10 |
|---|---|---|
| `Dashboard` (`types.ts` + contrato §3.2 + mock) | `{nombre, balance_total, transacciones[≤8, recientes primero], cdts:{activos:int, generado}, creditos:{cuota_por_pagar, interes_corriendo}}`; `nombre` = **nombres** (saludo); el mock suma `generado` solo de los CDT **activos** y `cuota_por_pagar` e `interes_corriendo` **sobre todos los créditos** | `nombre` = `usuario.nombres`; `cdts.generado` = Σ `generado_acumulado` de CDT **ACTIVOS** (coherente con «activos» y con `balance_total`, que ya usa solo los activos); `cuota_por_pagar` = Σ `valor_cuota` de la **próxima cuota impaga de cada crédito ACTIVO** (0 si no hay; **sin mora**: el campo es «la cuota», la mora vive en `vista_creditos.mora_acumulada`); `interes_corriendo` = Σ `_interes_corriendo` de los créditos ACTIVOS (= Σ `interes_mes` de `vista_creditos`, D-E8-4 / contrato §7.4). **Técnica; resuelta con el mock y el contrato** (el comentario del contrato dice «próxima cuota impaga» en singular, pero el front rotula «Cuota por pagar» para todos sus créditos y el mock suma). |
| `Transaccion` (contrato §3.2) | `{id, tipo:'envio'\|'recibo', tipo_detalle, monto>0, fecha ISO, contraparte, nota\|null}`; entre cuentas «Nombre Apellido · 4001002003»; movimientos del banco «Banco Digital»; CDT/crédito/bolsillo: nombre del producto | Una fila **por operación** (grupo del libro), no por pata (§3). `id` = id de la pata visible. `tipo_detalle` = enum real (el front aún no lo usa). |
| Dirección de cada uno de los 17 tipos | El contrato lista `sale` (ENVIO, BOLSO_INGRESO, CDT_CREACION, CREDITO_CUOTA/ABONO/MORA, «RETIRO…») y `entra` (RECIBO, BONO_REFERIDO, DESEMBOLSO, CDT_VENCIMIENTO, INTERES_*, INGRESO_SIMULADO, AJUSTE_ADMIN según signo); «RETIRO…» es ambiguo | **La dirección sale del `sentido` de la pata visible** (`S` = envío, `E` = recibo): reproduce **exactamente** la lista del contrato y resuelve «RETIRO…»: `BOLSO_RETIRO` entra a la principal ⇒ recibo. Sin tabla de 17 casos que mantener. |
| Movimientos internos cuenta↔bolsillo (D8, contrato §7.2) | «Default propuesto: mostrarlos». El diseño v3 (C.5/E.6) proponía ocultar `INTERES_CDT` (no es liquidez) pero el **contrato dice «INTERES_* entra»** | **D8 queda del equipo/front** (§8). E10 implementa el **default del contrato** (todo visible) con **un solo punto de cambio** (`_reglas_historial()`), sin decidir por ellos. |
| Orden de «recientes primero» | Solo dice «recientes primero» | `ORDER BY orden DESC` (decisión ya documentada en E3, E7 D-E7-6 y E9 §5.8): los cobros automáticos y los cierres de CDT llevan la fecha del día en que debieron ocurrir y se escriben al «descubrirlos»; dentro de un recorrido del motor `orden` ya es cronológico. La `fecha` mostrada es la real del asiento. |
| `p_limite` | «máx. 50»; el front manda `?limite=50` | NULL ⇒ 50; se **acota a [1, 50]** (0, negativos o 1000 no son errores de negocio y no hay mensaje en §6: **sin mensaje nuevo**, D13 intacta). |
| **Hallazgo — `vista_cdts.fecha_cierre` (E7)** | El contrato dice **«fecha_cierre: timestamptz ISO»** y `Cdts.tsx` hace `fechaHora(c.fecha_cierre)` = `new Date(iso).toLocaleString('es-CO')` | E7 devuelve `"2026-12-24"` (solo fecha, comprobado en el experimento). `new Date('2026-12-24')` se interpreta **en UTC**, así que en Colombia el front mostraría **23/12 7:00 p. m.**: un día antes. **Corrección propuesta (D-E10-5):** devolver el instante del cierre `fecha_fin` 00:00 Bogotá en ISO con zona (`2026-12-24T00:00:00-05:00`, el mismo instante en que E7 fecha el cierre). Cambia **una expresión** de `18_cdt.sql` y el `fecha_cierre` esperado de `55_cdt`. |
| `balance_total` / `total` (**D6**) | **Tres fuentes dicen «neto de deuda»:** contrato §3.2 («principal + bolsillos + CDT activos − capital pendiente»), spec §7.6 y plan Task 7. E6–E8 lo dejaron provisional (sin restar deuda) por ser del equipo | E10 **no cambia `balance_total`**: dashboard y `vista_balance` usan la **misma** función (única definición). Es la decisión más visible de la etapa: ver D-E10-D6 (§8) con su efecto exacto. |
| Zona horaria de las fechas | «ISO con zona»; el servidor corre en UTC; el DB tiene `TimeZone = America/Bogota` | Las 2 funciones nuevas llevan `SET TimeZone = 'America/Bogota'` **por código** (E3: «zona por código, no por sesión»). Las ya aprobadas que emiten un `timestamptz` (`solicitar_credito`, `pagar_cuota`, `abonar_credito`) dependen del valor del DB; se **prueba** (§9) y se documenta para Juan que su pool **no debe** sobrescribir `TimeZone`. |

## 3. La regla de «fila visible» (el corazón de E10) — comprobada

Cada operación del libro son 2–3 patas de la **misma cuenta** (o de dos cuentas, en un envío). El historial muestra **una fila por operación**: **la pata de mi cuenta en un contenedor de liquidez, con prioridad `CUENTA` > `BOLSILLO` > `CDT`** (las patas `CREDITO` y `RESULTADO` nunca se muestran; en `BOLSO_MOVIMIENTO`, que tiene dos patas de bolsillo, la de sentido `S`). Dirección = sentido de esa pata. Monto = monto de esa pata. Contraparte = snapshot de esa pata.

Ejecutado con una cuenta que hizo **todo**: envío (de la principal y de un bolsillo), recibo, bolsillos (ingresar, mover, retirar), CDT (crear y vencer, con su interés), crédito (desembolso, cuota, abono), intereses de bolsillo, ingresos simulados y un depósito del banco → **39 patas en 20 grupos → 20 filas, exactamente una por grupo, sin ninguna oculta ni duplicada**:

| tipo (pata visible) | contenedor | dirección | contraparte mostrada | nota |
|---|---|---|---|---|
| ENVIO / RECIBO | CUENTA (o BOLSILLO si se envió desde un bolsillo) | envío / recibo | `Beto Vista · 4014630006` | la del usuario |
| BOLSO_INGRESO / BOLSO_RETIRO | CUENTA | envío / recibo | nombre del bolsillo (`Viajes`) | — |
| BOLSO_MOVIMIENTO | BOLSILLO (la `S`) | envío | bolsillo destino (`Emergencias`) | — |
| INTERES_BOLSO | BOLSILLO | recibo | `Banco Digital` | `45 días` |
| CDT_CREACION / CDT_VENCIMIENTO | CUENTA | envío / recibo | nombre de la definición (`Demo CDT 30`) | — |
| INTERES_CDT | CDT | recibo | `Banco Digital` | `30 días` |
| CREDITO_DESEMBOLSO | CUENTA | recibo | nombre del producto | — |
| CREDITO_CUOTA / CREDITO_ABONO / CREDITO_MORA | CUENTA (el total pagado) | envío | nombre del producto | `Mora cuota 2` (mora) |
| INGRESO_SIMULADO / BONO_REFERIDO / DEPOSITO_BANCO | CUENTA | recibo | `Banco Digital` | `Ingreso simulado` |
| AJUSTE_ADMIN (E11) | CUENTA | según el signo | `Banco Digital` | la nota del admin |

**Contraparte (cadena de respaldo, el único JOIN con productos):** (1) `contraparte_nombre` de la pata, con ` · <contraparte_cuenta>` **solo** en ENVIO/RECIBO (el bono de referido guarda la cuenta del referido y no debe mostrarla); (2) si es NULL (el experimento lo encontró en el `DEPOSITO_BANCO` de una demo), el nombre de su bolsillo/CDT/producto (`LEFT JOIN`); (3) `Banco Digital`. Contrato: `contraparte` nunca es null.
**Dos hechos medidos que condicionan el diseño:** (a) `orden DESC` y `fecha DESC` dieron el mismo top-5 en el experimento, pero solo porque no hubo cobros atrasados: se mantiene `orden` por lo ya aprobado; (b) un salto de 45 días escribió **2 filas `INTERES_BOLSO` + 1 `INTERES_CDT`**: con muchos bolsillos/CDT el historial se llena de intereses (otro motivo de D8).

## 4. Funciones, vista y permisos

| Objeto | Tipo | Detalle |
|---|---|---|
| **`vista_dashboard(p_usuario_id uuid)`** → `jsonb` | pública, `SECURITY DEFINER`, `SET search_path = public, pg_temp`, `SET TimeZone` | **GET /dashboard.** Orden idéntico a E6/E7/E8/E9: `_validar_cliente` (sesión, `Acceso denegado`, bloqueo con su mensaje exacto) → cuenta del usuario (`Sesión inválida` si desapareció) → **UNA** `_reloj_instantanea()` → **`_avanzar_hasta`** (devenga, cierra CDT vencidos y cobra cuotas con descuento **antes** de leer; ahí el dashboard «incluye el avance de reloj» que pide el contrato) → **UNA sola sentencia** que arma las 5 secciones (una sola foto). |
| **`vista_historial(p_usuario_id uuid, p_limite integer DEFAULT 50)`** → `jsonb` (arreglo, `[]` si no hay) | pública, igual | **GET /transacciones?limite=N.** Mismos pasos; `p_limite` acotado a [1, 50]. El arreglo = `_json_transacciones(cuenta, p_limite)`. Firma = la del contrato (§3.2). |
| `_json_transacciones(p_cuenta_id uuid, p_limite integer)` → `jsonb` | interna, `STABLE` (sin EXECUTE para nadie salvo el dueño) | **Un solo formateador** de `Transaccion[]` para el dashboard (8), el historial (≤ 50) y, en E11, `admin_detalle_usuario` (50): una sola forma de armar el JSON. Lee `v_transaccion_usuario`. |
| `_reglas_historial()` → `jsonb` | interna, `IMMUTABLE` | **Valores provisionales de D8 en un solo lugar:** qué familias se muestran (`bolso`, `interes_bolso`, `interes_cdt`; default = todas, como el contrato) y el tope 50. Cambiar D8 = cambiar este cuerpo. |
| **`v_transaccion_usuario`** | **vista real**, dueño `banco_owner` | Columnas: `cuenta_id, usuario_id, id, orden, grupo_id, fecha, tipo` (`envio`/`recibo`), `tipo_detalle, monto, contraparte, nota`. Implementa §3: `transaccion` filtrada a las patas de liquidez de la cuenta, con `NOT EXISTS` de una pata de mayor prioridad del mismo grupo y cuenta (por `ix_transaccion_grupo`), `JOIN cuenta` (para `usuario_id`) y `LEFT JOIN bolsillo/cdt/credito→credito_producto` (respaldo del nombre). Consultada por `WHERE cuenta_id = … ORDER BY orden DESC LIMIT n` usa `ix_transaccion_cuenta_orden`: **O(límite)**, no O(historia). |
| `v_integridad_defensas` (E2) | ampliada | lista blanca de `banco_app`: **24 → 26** y una fila nueva: **`banco_app` no tiene SELECT sobre `v_transaccion_usuario`** (ver abajo). |

**Permisos.** Las 2 públicas: `EXECUTE` solo para `banco_app` (`banco_dev` hereda); los 2 helpers: nadie. **Diferencia justificada con E1 §8.2 («Vistas `v_*`: `banco_app` `SELECT` (E10)») y con el contrato §1 («SELECT sobre vistas»):** *no* se otorga `SELECT` de `v_transaccion_usuario` a `banco_app`. La vista mira **todas** las cuentas; un `SELECT` directo permitiría al backend (o a una inyección) leer el historial **de cualquiera**, saltándose la propiedad que hoy fuerza `p_usuario_id` + `_validar_cliente`. Todo el banco entrega por funciones (E4–E9) y el contrato no nombra ninguna vista; `banco_lector`/`banco_dev` sí la leen (consulta, JOIN para la defensa del proyecto). Triggers: **sin cambios (21)**. Tablas: **sin cambios**.
**Cifras esperadas:** 105 → **109 funciones**, 8 → **9 vistas**, `banco_app` ejecuta **26**, plantillas 20, triggers 21.

## 5. Consistencia, concurrencia e integración

* **Lectura consistente:** principal, bolsillos, CDT, créditos y las 8 transacciones salen de **una sola sentencia** (una foto del `READ COMMITTED`): `balance_total` (`STABLE`) y el historial nunca se ven a medias de un movimiento concurrente (mismo mecanismo de `vista_balance`, probado en E6). Las secciones del dashboard son **las mismas funciones** que alimentan los otros endpoints (`balance_total`, `_proxima_cuota`, `_interes_corriendo`), así que `dashboard` y `GET /bolsillos`, `GET /cdts`, `GET /creditos/mis-creditos` **no pueden discrepar** (se prueba).
* **`_avanzar_hasta`:** las 2 funciones entran al **catálogo de `54_devengo`** como «devengan»: cada una llama `_avanzar_hasta(` y `_reloj_instantanea()` **una sola vez**, la instantánea primero, sin leer el reloj por su cuenta (`now()`, `hoy_banco()`… prohibidos; el escaneo las exige). Una función nueva sin clasificar hace fallar la suite (así E8/E9 ya lo heredaron).
* **Bloqueos:** ninguno propio. La salida rápida de `_avanzar_hasta` no bloquea; si hay devengo/cobro pendiente toma el mismo `FOR NO KEY UPDATE` de la cuenta que las demás operaciones y lo conserva hasta el COMMIT (orden global ya probado ⇒ sin deadlock con transferencias cruzadas, pagos y abonos). El front dispara 2–3 GET paralelos (`/dashboard`, `/bolsillos`, `/transacciones`): se serializan **solo** si hay algo pendiente, y el segundo ya no encuentra nada.
* **Las lecturas escriben** (cobros, intereses, cierres): atómicas y sin rastro si fallan (probado por E7/E9 para `vista_cdts`/`vista_creditos`; E10 repite **una** inyección de falla sobre el dashboard para probar la integración, no el mecanismo).
* **Carreras con el borrado del usuario:** `Sesión inválida`, nunca un error no-P0001 (patrón E5–E9).
* **Ningún dato nuevo se persiste.** Sin columnas, sin triggers, sin tablas: lo derivado se recalcula en cada lectura.

## 6. Reglas de integridad (qué garantiza E10)

1. **Una fila por operación visible**: `#filas = #grupos con alguna pata de liquidez`; ningún grupo se pierde ni se duplica; ninguna fila de `CREDITO`/`RESULTADO`.
2. **Monto = el de la pata visible** (siempre > 0; el signo lo da `tipo`); `tipo ∈ {envio, recibo}`; `contraparte` nunca null; `nota` null si no hay.
3. **Propiedad:** solo se leen legs con `cuenta_id` de **mi** cuenta; el admin recibe `Acceso denegado`; el bloqueado, su mensaje exacto.
4. **Dashboard = suma de partes:** `balance_total` = `vista_balance.total`; `transacciones` = prefijo de 8 de `vista_historial`; `cdts` = Σ de `vista_cdts` activos; `creditos.interes_corriendo` = Σ `interes_mes`; `cuota_por_pagar` = Σ próxima cuota.
5. **Dinero como número, fechas ISO con zona, listas `[]`, ningún `numeric` como string** (contrato §2/§8) — en las 26 salidas.

## 7. Diferencias justificadas respecto al diseño original

| Original | E10 | Por qué |
|---|---|---|
| Plan Task 9: `vista_historial … RETURNS TABLE(...)`, `vista_cdts/creditos` como tablas | todo **`jsonb`** | D3 aprobada (2026-11-21); el front recibe arreglos de objetos. |
| Diseño v3 B.3: 6 vistas reales (`v_transaccion_usuario, v_balance_usuario, v_cdt_estado, v_credito_resumen, v_usuario_admin, v_integridad_saldos`) | **1 vista nueva** (`v_transaccion_usuario`); `v_integridad_saldos` ya existe (E2); `v_usuario_admin` es de E11 | `v_balance_usuario`/`v_cdt_estado`/`v_credito_resumen` duplicarían `balance_total`, `vista_cdts` y `vista_creditos` (ya aprobadas): **dos definiciones del mismo dato** son un riesgo, no un valor. La vista que sí aporta es la que encapsula la regla de fila visible (la única lógica nueva). Si el equipo quiere más vistas para la defensa académica: D-E10-7. |
| E1 §8.2: `banco_app` `SELECT` sobre `v_*` | **no se otorga** | §4 (fuga entre usuarios). |
| E7: `fecha_cierre` = `YYYY-MM-DD` | instante ISO con zona | §2 (contrato + bug visible del front). |
| Diseño v3 C.5/E.6: ocultar `INTERES_CDT` | visible (default del contrato), configurable | La decisión es D8 (front/equipo); no se anticipa. |

## 8. Decisiones

**Técnicas (las aprueba el responsable de BD; sin efecto financiero ni de contrato):**

| ID | Decisión | Recomendación |
|---|---|---|
| **D-E10-1** | Alcance: 2 públicas + 2 internas + 1 vista + conformidad con el contrato + `precision.test.mjs` + tabla maestra para Juan. Nada de front/backend. | Aprobar. |
| **D-E10-2** | Regla de **fila visible** y dirección por `sentido` (§3); `orden DESC`; `contraparte` con respaldo; `p_limite` acotado a [1, 50] sin mensaje nuevo. | Aprobar. |
| **D-E10-3** | Dashboard: `nombre` = nombres; `cdts.generado` solo ACTIVOS; `cuota_por_pagar` = Σ próxima cuota (sin mora) de cada crédito ACTIVO; `interes_corriendo` = Σ. | Aprobar. |
| **D-E10-4** | Una sola sentencia, una instantánea, `_avanzar_hasta` primero; el catálogo de `54` las clasifica como «devengan» (15 → **17**). | Aprobar. |
| **D-E10-5** | **Corregir `vista_cdts.fecha_cierre`** a ISO con zona (edita una expresión de E7 y `55`). | Aprobar (bug visible, conforme al contrato). |
| **D-E10-6** | `banco_app` **sin** `SELECT` en `v_transaccion_usuario` (fila nueva en `v_integridad_defensas`; lista blanca 24 → 26). Edita `09_integridad.sql`. | Aprobar. |
| **D-E10-7** | Solo **1** vista real nueva. ¿Se quieren `v_balance_usuario`/`v_cdt_estado`/`v_credito_resumen` solo para la defensa académica? | No incluir (duplican definiciones aprobadas). |
| **D-E10-8** | `SET TimeZone = 'America/Bogota'` por código en las 2 funciones nuevas; las existentes no se tocan y se **prueban** con la sesión en UTC (si alguna falla se corrige con `ALTER FUNCTION … SET TimeZone`, un cambio de configuración, no de código). | Aprobar. |
| **D-E10-9** (ajustada por el responsable de BD) | `precision.test.mjs` queda **independiente** del runner (`node db/tests/precision.test.mjs`, evidencia en `docs/db/evidencias/10-precision.txt`), sin cambiar `ctl.sh`/`ctl.ps1`. **Alcance exacto de la garantía:** la conservación **exacta de centavos** vale **solo dentro del rango que JavaScript `Number` representa sin pérdida**: importes con 2 decimales y |valor| **< 10¹³ pesos** (centavos < 10¹⁵ < 2⁵³). **No** se garantiza para todo el dominio `NUMERIC(18,2)` (hasta 10¹⁶): por encima de ese rango un `Number` no distingue centavos. Por eso la BD **rechaza** todo importe ≥ 1e13 (`dinero` y `_validar_monto`, E1/E5), y la prueba verifica **las dos mitades**: (a) precisión exacta de centavos dentro del rango (aleatorios + extremos 0,01 … 9.999.999.999.999,99 y negativos de `total`), (b) rechazo de 1e13 y de los valores superiores (`Monto inválido` / violación del dominio), y que ninguna salida real de E10 pueda llevar un importe fuera del rango. | Aprobada con este ajuste. |

**Del equipo (no se programan como definitivas; hay un valor provisional centralizado):**

| ID | Decisión | Estado en E10 |
|---|---|---|
| **D6** | ¿Qué cifra es el «balance total»? Contrato §3.2, spec §7.6 y plan dicen **neto de deuda**; E6–E8 la dejaron sin restar. **Hoy:** pedir un crédito de 10 M **sube** el total mostrado en 10 M (la deuda no se resta) y el dashboard de E10 muestra ese valor. **Si adoptan el neto:** cambia `balance_total` (una línea) y `_patrimonio_neto` pasa a alias; hay que invertir las aserciones de `58` («balance_total no cambia») y la `total` puede ser **negativo** (con la semilla del contrato `jperez483` quedaría en ≈ −6,65 M); el front ya formatea negativos. | **No cambia.** Dashboard y `/bolsillos` usan la misma función, así que decidirlo después no toca E10. **Recomendación (para el equipo): adoptar el neto**, que es lo que dicen las tres fuentes. |
| **D8** | Historial: ¿se muestran los movimientos cuenta↔bolsillo y los intereses de bolsillo/CDT? | **Default del contrato (todo visible)** en `_reglas_historial()`. |
| **D10** | Firmas: `vista_dashboard(p_usuario_id)` y `vista_historial(p_usuario_id, p_limite)` **coinciden con el contrato**; cero diferencias nuevas. | Sin acción. |
| **D13** | Mensajes: **ninguno nuevo** (`Sesión inválida`, `Acceso denegado`, bloqueo, `Recurso no encontrado`). | Sin acción. |

**Las 6 preguntas abiertas del contrato §7, tras revisar las fuentes:** (1) tasas en porcentaje E.A.: ya así en toda la frontera, la convención interna sigue siendo D1 del equipo; (2) movimientos internos: **D8** arriba; (3) `productos_publicos()`: **hecho** (E8); (4) interés corriendo = interés del período en curso aún no pagado: **hecho** (D-E8-4); (5) `tiempo_restante` como texto: **hecho** (E7, «N días», «1 día», «Cerrado»); (6) lista de nombres de funciones: **se entrega** en `10-resumen-para-juan.md`.

## 9. Plan de pruebas (ágil: solo riesgos nuevos; no se repite E1–E9)

| Archivo | Riesgo que cubre | Aserciones aprox. |
|---|---|---|
| `65_vistas_historial.test.sql` | Un escenario con **los 17 tipos** (incl. `AJUSTE_ADMIN` ±, bono, mora) y el historial **exacto** (tipo, detalle, monto, contraparte, nota, orden) contra el §3; **una fila por grupo**; envío desde bolsillo; contraparte con respaldo y sin la cuenta en el bono; `BOLSO_MOVIMIENTO` una fila; cobro automático **atrasado**: la fila lleva la fecha real y `orden` la acomoda; `p_limite` (NULL, 0, −5, 1, 50, 51, 1000); reloj +30 días: ya trae el interés; usuario nuevo = 5 ingresos; `[]` sin movimientos; D8 apagado en `_reglas_historial` oculta lo que debe; **uso del índice** (plan sin `Seq Scan` con ≥ 5000 patas); dashboard: cada sección contra su fuente (**coherencia entre `/dashboard`, `/bolsillos`, `/cdts`, `/creditos/mis-creditos`**), sin créditos/CDT = 0; falla inyectada en un cobro disparado por el dashboard (todo o nada); **una sola instantánea** (conteo dinámico) | ≈ 70 |
| `66_vistas_aleatorio.test.sql` | ~150 operaciones aleatorias (todas las de E5–E9) con un **oráculo independiente** (grupos con pata de liquidez, calculado sin la vista): filas = grupos, montos y direcciones, `dashboard.balance_total = vista_balance.total`, prefijo de 8, ningún id repetido, `v_integridad_global.ok` | ≈ 10 |
| `67_contrato.test.sql` | **Conformidad con el contrato de las 26 salidas** (una llamada de cada una): nombres y **tipos JSON** contra `types.ts` (`assert_json_shape`), dinero como **número** (recorrido recursivo: ningún `numeric` como string), fechas ISO con zona `-05:00` **con la sesión en UTC** (y `YYYY-MM-DD` donde corresponde), ids como string, listas `[]`; **los 15 mensajes de §6 byte a byte** presentes en el catálogo (acentos incluidos) | ≈ 55 |
| `reales/51_vistas_conexiones.sh` | Roles reales por TCP (`banco_app`, sin superusuario): conversación del backend, **`EXECUTE` en las 2 nuevas y en ninguna interna, `SELECT` denegado sobre la vista**, lector/dev la leen, `p_usuario_id` ajeno imposible (no hay parámetro de otra cuenta), admin → `Acceso denegado`, bloqueado → mensaje exacto, usuario borrado → `Sesión inválida`, **corte de conexión** a mitad de un cobro disparado por el dashboard | ≈ 25 |
| `reales/52_vistas_concurrencia.sh` | Lectores del dashboard/historial **mientras** otros mueven dinero entre principal y bolsillos (el `balance_total` leído es siempre el mismo y el historial nunca trae una pareja a medias), 12 dashboards simultáneos con un cobro pendiente (**un solo cobro**), transferencias cruzadas ∥ dashboards (sin deadlock) | ≈ 12 |
| `precision.test.mjs` (Node, fuera del runner) | **D.8:** ≥ 100 000 importes `NUMERIC(18,2)` (aleatorios + extremos: 0,01, 0,29, 1,005-tipo, 9.999.999.999.999,99 y negativos de `total`, **todos < 1e13**) por `jsonb` → `JSON.parse` → centavos recuperados = centavos originales en el 100 %; más los extremos por las salidas reales (`vista_balance`, `vista_dashboard`); **y el rechazo de 1e13, 1e13 + 0,01 y 1e15 en el dominio y en `_validar_monto`**; la garantía se declara **solo dentro del rango de `Number`** | ≈ 10 |

**Adaptaciones de pruebas anteriores (solo inventarios, ninguna se elimina):** `03_schema` (109 funciones, 9 vistas), `10`/`52`/`55`/`reales/45`/`reales/47` (lista blanca 26), `54` (catálogo: devengan 17), `55` (`fecha_cierre` ISO), `09_idempotencia` (reaplica `23_vistas.sql` y `18_cdt.sql`), `16` (fila de defensa nueva). Script nuevo: **`db/sql/23_vistas.sql`** (+ la edición de una expresión de `18_cdt.sql` y de la lista blanca de `09_integridad.sql`). **Estimado: ≈ +170 aserciones.**

**Mutaciones nuevas ≈ 28** (M306…): regla de fila visible (prioridad invertida, sin la excepción de `BOLSO_MOVIMIENTO`, una fila por **pata**, incluir `RESULTADO`/`CREDITO`); dirección invertida; contraparte sin respaldo o con la cuenta en el bono; `ORDER BY fecha`; `LIMIT` sin acotar o sin tope; dashboard con `cdts.generado` de todos, `cuota_por_pagar` con mora o de un solo crédito, `interes_corriendo` de un crédito; sin `_avanzar_hasta` (cada función); doble instantánea; `now()`; sin `SET TimeZone`; `fecha_cierre` en fecha; `GRANT SELECT` de la vista a `banco_app`; `GRANT EXECUTE` de un helper; `SECURITY INVOKER`; D8 que no oculta o que oculta de más. Regresión: las mutaciones de E7 sobre `vista_cdts` (M142, M170) y las de permisos (M171–M174, M214–M217).

## 10. Riesgos y límites

1. **D6 es lo más visible:** hasta que el equipo decida, el «Balance total» sube al pedir un crédito (documentado desde E8). No es un defecto de E10 sino la decisión pendiente; está aislado en una función.
2. **El historial puede llenarse de intereses** (una fila por bolsillo y por CDT en cada devengo): es la razón de D8; con el default del contrato se ven.
3. **`orden` ≠ cronología estricta de `fecha`** cuando el motor descubre cobros atrasados (límite ya documentado en E3/E7/E9); la fecha mostrada es la real.
4. **Una vista sin `SELECT` para `banco_app` no la usa el backend**: la defensa académica de «vistas» se apoya en `banco_lector`/`banco_dev` y en las funciones que la consumen.
5. **Las lecturas toman el bloqueo de la cuenta cuando hay algo pendiente** (costo aceptado a esta escala, como en E7–E9).
6. **Seed (E14):** el seed debe crearse llamando a las funciones reales; el dashboard de `jperez483` dependerá de D6 y D11 (catálogo).
