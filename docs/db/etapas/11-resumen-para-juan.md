# Etapa 11 — Administración · resumen para el backend (Juan)

**Doce funciones `admin_*`** (todas con **`p_admin_id` primero**, el de la sesión; la BD vuelve a verificar que sea un **ADMIN activo** antes de leer nada). Devuelven **`jsonb`** y los errores de negocio llegan como `P0001` con el mensaje exacto → responde **400** con ese texto (`Recurso no encontrado` y `Acceso denegado` → **403**). Cualquier otro error sigue siendo 503. **Los nombres coinciden con los del borrador de backend (`admin.ts` / `WHITELIST` de `origin/main`), que es temporal: la referencia es esta tabla y el contrato.**

| Endpoint | Llamada (argumentos como en tu `admin.ts`) | Devuelve |
|---|---|---|
| `GET /admin/usuarios?busqueda=` | `admin_listar_usuarios(admin, busqueda text)` → **jsonb** (`''` o `NULL` = todos) | `[{ id, username, nombre, cedula, correo, numero_cuenta, estado }]` — **solo clientes**, máx. 200 |
| `GET /admin/usuarios/:id` | `admin_detalle_usuario(admin, id text)` | `{ …lo anterior…, balance: { total, principal, bolsillos[{id,nombre,saldo}], cdts[{id,monto}] activos, creditos[{id,producto,saldo}] activos }, historial: Transaccion[≤50] }` |
| `POST /admin/usuarios/:id/bloquear` · `/desbloquear` | `admin_bloquear(admin, id)` · `admin_desbloquear(admin, id)` | `{ id, estado }` (idempotentes) |
| `DELETE /admin/usuarios/:id` | `admin_borrar_usuario(admin, id)` | `{ id, borrado: true }` |
| `POST /admin/balance` | `admin_ajustar_balance(admin, usuario_id, monto, nota)` | `{ id, monto, fecha }` |
| `GET /admin/reloj` | `admin_get_reloj(admin)` | `{ usar_fecha_real, fecha_sistema \| null, fecha_actual }` |
| `PUT /admin/reloj` | `admin_set_reloj(admin, usar_fecha_real, fecha_sistema ?? null)` | la misma vista |
| `GET /admin/tasas` | `admin_get_tasas(admin)` | `{ cdts[{id,nombre,tasa}], creditos[{id,nombre,tasa}], mora }` (números) |
| `PUT /admin/tasas` | **en UNA transacción (como el `db.tx` del borrador):** `admin_set_tasa_cdt(admin, id, tasa)` por cada CDT, `admin_set_tasa_credito(admin, id, tasa)` por cada producto y `admin_set_tasa_mora(admin, tasa)` | `{ id, tasa }` / `{ mora }` |
| `GET /admin/esquema` · `/tabla/:n` | `admin_esquema(admin)` · `admin_tabla(admin, nombre, pagina text)` | **E12** (implementadas; ver `12-resumen-para-juan.md`) |

## Sobre el backend actual (aviso importante)

**El backend de `origin/main` es un borrador temporal y NO es fuente de autoridad** (el desarrollo del backend definitivo aún no empieza). Las decisiones de E11 salen del contrato, de `types.ts` y de la BD; este resumen describe **la BD terminada**. Cuando se haga el backend definitivo, vuelve a contrastar todo contra esos tres, sin dar nada por bueno del borrador.

Un ejemplo de lo que cambia: el borrador lee `GET /admin/usuarios` con `db.call(...)` (espera un conjunto de filas), pero la BD devuelve **`jsonb`** (decisión D3 de todo el proyecto) en una sola celda: **todas** las funciones de la BD deben leerse así (tu helper `json()` del borrador hace eso). Existe un parche de 2 líneas que lo corrige en el borrador, [`11-parche-backend-usuarios.patch`](11-parche-backend-usuarios.patch), pero se conserva **solo como referencia descartable**: **no está integrado en ninguna rama** y no hay que aplicarlo al borrador.

## Cosas que debes saber

* **Ids siempre como texto.** Un id mal formado, inexistente o de un administrador es de negocio (`Recurso no encontrado`), nunca un error de driver. **`admin_ajustar_balance` acepta como `usuario_id` un uuid, el username o el número de cuenta** (el front no muestra el uuid; tu README pide «id o username»). `monto` puede ir como número o texto, **con signo** (positivo suma, negativo resta); `0`, más de 2 decimales o ≥ 1e13 = `Monto inválido`; un ajuste negativo que dejaría la cuenta bajo cero = `Saldo insuficiente`. `nota` opcional (≤ 140; `Nota inválida`).
* **Las tasas llegan como texto o número** (`"12.5"` / `12.5`, como `String(...)` del front): válido `0 < t ≤ 100` con hasta 3 decimales; si no, **`Tasa inválida`** (mensaje nuevo, provisional D13). Un id de CDT/producto inexistente = `Recurso no encontrado` (ya no se ignora en silencio). **`PUT /admin/tasas` DEBE seguir ejecutándose en UNA transacción (`db.tx`)**: cada función es atómica por sí sola y las tres toman un *advisory lock* (dos formularios simultáneos se serializan), pero que o se apliquen las tres o ninguna lo da **tu transacción**; la BD no puede forzar que la abras. Guardar un valor igual al actual no cambia nada ni audita.
* **Mora sin valor (provisional, equipo — D-E11-D7a):** mientras el equipo no decida D7, `tasa_mora_anual` está vacía; `admin_get_tasas` devuelve `mora: 0` (para que el formulario del front pueda guardarse) y `admin_set_tasa_mora('0')` significa «sin mora» (se guarda vacío). **Pendiente de confirmación del equipo (D-E11-D7b):** como la mora de E9 es *derivada*, cambiar `mora` cambia también la mora de las cuotas que **ya están vencidas**; E11 no decide ni agrega nada sobre eso.
* **`PUT /admin/reloj`:** manda `fecha_sistema ?? null`; en modo real (`usar_fecha_real = true`) la fecha se **ignora**. Retroceder = `El reloj no puede retroceder`; fecha inválida = `Fecha inválida`.
* **Bloquear rige desde la siguiente petición del usuario** (`validar_sesion` relee el estado); un bloqueado **sí puede recibir** dinero (D-E5-9, equipo). **Borrar es en cascada y no reversible** (cuenta, productos y libro); las operaciones del usuario en vuelo terminan con `Sesión inválida`; el historial de los demás conserva «Nombre · cuenta» del borrado (la contraparte es texto).
* **Consultar el detalle de un usuario puede escribir** (cobra una cuota con descuento automático, devenga intereses o cierra un CDT vencido), como cualquier lectura de saldos; es idempotente.
* **Auditoría:** cada acción con efecto deja un evento en `audit.evento` (actor = el admin). El backend no la lee ni la escribe.
* **Sin cuentas de administrador en la BD recién aplicada:** el primer ADMIN lo crea el seed (E14).

## Fuera de E11 (lo descubrí al leer tu backend; no lo toqué)

Los endpoints de **cliente** de `origin/main` también chocan con las firmas reales de E4–E10 (p. ej. `vista_historial`, `vista_cdts`, `vista_creditos`, `listar_cdt_definiciones` y `productos_publicos` devuelven `jsonb` y se leen como filas; `nombre_destinatario`, `simular_cdt`, `simular_credito` y `listar_cdt_definiciones` llevan `p_usuario_id`; `renombrar_bolsillo` y el `correo` de `vista_perfil` no existen en la BD). Los resúmenes `04`–`10` describen las firmas reales. Hace falta una **revisión de integración backend ↔ BD independiente**, que ninguna etapa cubre.
