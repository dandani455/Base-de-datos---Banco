# Etapa 10 — Vistas del contrato · resumen para el backend (Juan)

Dos funciones nuevas (las últimas de cliente que faltaban en el contrato §3) y la **tabla maestra** endpoint → función que el contrato §7.6 pide. Las de cliente reciben `p_usuario_id` (el de la sesión), devuelven **`jsonb`** y los errores de negocio llegan como `P0001` con el mensaje exacto → responde **400** con ese texto (`Recurso no encontrado` → **403**). Cualquier otro error sigue siendo 503.

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `GET /dashboard` | `SELECT vista_dashboard($1 /*usuario_id*/)` | `{ nombre, balance_total, transacciones: Transaccion[≤8], cdts: { activos, generado }, creditos: { cuota_por_pagar, interes_corriendo } }` |
| `GET /transacciones?limite=N` | `SELECT vista_historial($1, $2 /*limite, ENTERO*/)` | `Transaccion[]` = `[{ id, tipo: 'envio'\|'recibo', tipo_detalle, monto, fecha, contraparte, nota }]`, la más reciente primero; `[]` si no hay |

* **`limite`:** mándalo como entero (`Number.parseInt`); `NULL` o ausente = 50 y la BD lo **acota a [1, 50]** (0, negativos o 1000 no son error: no hay mensaje nuevo). Si el query-string no es un número, usa el default (50) en el backend.
* **Una fila por operación:** un envío entre cuentas es **una** fila (para el emisor «envío», para el receptor «recibo»); las patas internas del libro (deuda, intereses como gasto) no salen. `tipo` = dirección para pintar (rojo `-` / verde `+`); `tipo_detalle` = el tipo real (`CDT_CREACION`, `CREDITO_CUOTA`…; el front aún no lo usa). `contraparte` **nunca es null** («Nombre Apellido · 4000000002» entre cuentas, «Banco Digital», o el nombre del bolsillo/CDT/producto); `nota` puede ser `null`.
* **El historial se ordena por orden de escritura, no por `fecha`:** un cobro automático o el cierre de un CDT lleva la fecha del día en que debió ocurrir y se escribe al «descubrirlo», así que puede aparecer arriba con una fecha anterior a otra fila. **No reordenes por fecha en el backend** (muestra la lista tal cual).
* **`fecha` es ISO 8601 con zona de Bogotá** (`2026-11-24T14:32:05.123-05:00`) **aunque tu sesión pida UTC**: la zona la fijan las funciones. Importante: **no sobrescribas `TimeZone` en el pool** si no hace falta. (E10 también la fija en las funciones de E5–E9 que devuelven una fecha.)
* **Cambio respecto a E7 (`GET /cdts`):** `fecha_cierre` ahora es un **instante ISO con zona** (`2026-12-24T00:00:00-05:00`, como pide el contrato), no `2026-12-24`: con la fecha sola el front la mostraba un día antes (la interpretaba como UTC). No hay que tocar nada en el backend.
* **Las lecturas pueden escribir:** `vista_dashboard` y `vista_historial` corren el motor antes de leer (devengan intereses, cierran CDT vencidos y cobran cuotas con descuento automático). Idempotente: la segunda lectura no escribe nada.
* El `GET /dashboard`, `GET /bolsillos`, `GET /cdts` y `GET /creditos/mis-creditos` usan **las mismas funciones internas**: sus cifras coinciden siempre.

**Decisiones provisionales (del equipo) que te afectan**
* **D6 — «Balance total»:** `balance_total` = cuenta principal + bolsillos + CDT activos (con sus intereses). **No resta la deuda de los créditos** (el contrato dice que sí; el equipo lo decidirá): hoy, pedir un crédito **sube** el total mostrado. Cambiarlo es un cambio en la BD; el contrato de la respuesta no cambia.
* **D8 — qué se ve en el historial:** hoy **todo** (movimientos cuenta↔bolsillo e intereses de bolsillo y CDT, como propone el contrato). Si el front decide ocultar alguno, es un cambio de la BD; tu consulta no cambia. Ojo: tras un salto de reloj o varias consultas verás varias filas de interés (una por bolsillo y por CDT por devengo).

## Tabla maestra: endpoint del contrato → función de BD (todas con `p_usuario_id` primero salvo las indicadas)

| Endpoint | Función | Etapa |
|---|---|---|
| `POST /auth/registro` | `registrar_usuario(nombres, apellidos, cedula, correo, telefono, fecha_nacimiento text, password_hash, acepta_politica, codigo_referido text, verificacion_activa)` → `{usuario_id, username}` (entrega solo `{username}`) | E4 |
| `POST /auth/login` | `obtener_credenciales(username)` (0..1 fila `usuario_id, password_hash, rol, estado`) + `validar_sesion(usuario_id)` | E4 |
| `GET /yo` | `validar_sesion(usuario_id)` → `{username, rol, estado}` | E4 |
| `GET /perfil` | `vista_perfil(usuario_id)` → `{username, numero_cuenta, codigo_referido}`; `verificar_correo(usuario_id)` (void) | E4 |
| `GET /dashboard` | `vista_dashboard(usuario_id)` | **E10** |
| `GET /bolsillos` | `vista_balance(usuario_id)` → `{total, principal, bolsillos[]}` | E6 |
| `GET /transacciones?limite=` | `vista_historial(usuario_id, limite)` | **E10** |
| `GET /destinatario/:numero` | `nombre_destinatario(usuario_id, numero_cuenta)` → `{nombre}` (**D10:** lleva `p_usuario_id`) | E5 |
| `POST /envios` | `hacer_transferencia(usuario_id, numero_destino, monto text, nota, bolsillo_origen text)` | E5 |
| `POST /bolsillos` · `/bolsillos/:id/ingresar` · `/retirar` · `/mover` | `crear_bolsillo(usuario_id, nombre)` · `mover_a_bolsillo(usuario_id, bolsillo_id, monto)` · `retirar_de_bolsillo(usuario_id, bolsillo_id, monto)` · `mover_entre_bolsillos(usuario_id, origen, destino, monto)` | E6 |
| `GET /cdts/definiciones` | `listar_cdt_definiciones(usuario_id)` | E7 |
| `POST /cdts/simular` · `POST /cdts` · `GET /cdts` | `simular_cdt(usuario_id, definicion_id, monto)` · `crear_cdt(usuario_id, definicion_id, monto)` · `vista_cdts(usuario_id)` | E7 (`fecha_cierre` corregida en E10) |
| `GET /creditos/productos` | `productos_disponibles(usuario_id)`; landing sin sesión: `productos_publicos()` | E8 |
| `POST /creditos/simular` · `POST /creditos` · `GET /creditos/mis-creditos` | `simular_credito(usuario_id, producto_id, monto, plazo)` · `solicitar_credito(...)` · `vista_creditos(usuario_id)` | E8 (+2 campos en E9) |
| `POST /creditos/:id/abono` | `abonar_credito(usuario_id, credito_id text, monto text)` | E9 |
| *(sin endpoint en el contrato)* | `pagar_cuota(usuario_id, credito_id, numero)` · `activar_descuento_automatico(usuario_id, credito_id, activo)` | E9 |
| `/admin/*` | `admin_*` con `p_admin_id` **primero** (12 funciones en E11 y `admin_esquema`/`admin_tabla` en E12). **E11 IMPLEMENTADA (pendiente de auditoría; ver `11-resumen-para-juan.md`)**, con los nombres que ya usa tu `WHITELIST` de `origin/main`: `admin_listar_usuarios(admin, busqueda)` · `admin_detalle_usuario(admin, id)` · `admin_bloquear` · `admin_desbloquear` · `admin_borrar_usuario(admin, id)` · `admin_ajustar_balance(admin, usuario_id, monto, nota)` · `admin_get_reloj(admin)` · `admin_set_reloj(admin, usar_fecha_real, fecha_sistema)` · `admin_get_tasas(admin)` · `admin_set_tasa_cdt/_credito(admin, id, tasa)` · `admin_set_tasa_mora(admin, tasa)`. **Backend:** `PUT /admin/tasas` sigue con tu `db.tx` de 3 llamadas (sin cambios); el borrador de backend es temporal y no es fuente de autoridad (ver `11-resumen-para-juan.md`; el parche `11-parche-backend-usuarios.patch` es solo referencia descartable, no integrado) | **E11 / E12 (implementadas; ver `12-resumen-para-juan.md` para `admin_esquema` y `admin_tabla`)** |

Ids siempre como **texto**; montos como **texto** (`'500000'`), nunca `float`; mensajes de error = los del contrato §6 (ninguno nuevo en E10).
