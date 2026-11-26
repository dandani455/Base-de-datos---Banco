# Etapa 7 — Motor de devengo y CDT · resumen para el backend (Juan)

Cuatro funciones nuevas; todas reciben `p_usuario_id` (el de la sesión) y devuelven **`jsonb`**. Los errores de negocio llegan como `P0001` con el mensaje exacto → responde **400** con ese texto (`Recurso no encontrado` → **403**, como en E5/E6). Cualquier otro error sigue siendo 503.

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `GET /cdts/definiciones` | `SELECT listar_cdt_definiciones($1 /*usuario_id*/)` | `[{ id, nombre, tasa, plazo_dias, monto_min }]` (`[]` si no hay) |
| `POST /cdts/simular` `{definicion_id, monto}` | `SELECT simular_cdt($1, $2 /*definicion_id, texto*/, $3 /*monto como TEXTO*/)` | `{ generado_mes, generado_dia, generado_vencimiento }` |
| `POST /cdts` `{definicion_id, monto}` | `SELECT crear_cdt($1, $2, $3 /*monto TEXTO*/)` | `{ id, fecha }` (`id` = id del CDT) |
| `GET /cdts` | `SELECT vista_cdts($1)` | `[{ id, monto, generado_hasta_hoy, tiempo_restante, fecha_cierre }]` |

Qué cambia en lo que ya usabas (**sin cambios de contrato**, pero ahora pueden **escribir**):
* `GET /bolsillos` (`vista_balance`), `POST /bolsillos`, `POST /bolsillos/:id/{ingresar,retirar,mover}`, `POST /envios` (`hacer_transferencia`) y los CDT **devengan los intereses pendientes antes de leer o mover saldos** (cobro perezoso). Si el reloj avanzó, la primera consulta del día escribe los intereses; las siguientes no. No hay que llamar a ninguna función de «avanzar».
* `total` de `GET /bolsillos` **ahora incluye los CDT activos** (`monto + generado`): crear un CDT no baja el total. Sigue siendo **provisional** (D6 del equipo: la deuda de crédito no se resta todavía).
* Las respuestas de `vista_balance` ya traen los saldos de bolsillo **con** sus intereses.

Reglas para el backend (las mismas de E5/E6):
* **Ids como texto**: `definicion_id` va tal cual (texto); un uuid mal formado lo responde la BD como `Recurso no encontrado` (no un 503 del driver).
* **Monto como texto** (`'500000.50'`), no `float`: un `0.30000000000000004` da `Monto inválido`.
* El front no lee la salida de `crear_cdt` (basta 200); recarga con `GET /cdts` y `GET /bolsillos`.

Mensajes nuevos: **ninguno inventado**. `Monto por debajo del mínimo del CDT` (contrato §6) y `Recurso no encontrado` (definición mal formada o inexistente); el resto son los de E4/E5/E6 (`Monto inválido`, `Saldo insuficiente`, sesión).

Decisiones **provisionales** que te afectan (a confirmar con el front/equipo):
* **D-E7-7:** `listar_cdt_definiciones` y `simular_cdt` reciben `p_usuario_id` (el contrato no lo lleva; nos permite exigir sesión viva). `generado_mes` = lo generado en **30 días** (o en el plazo, si es menor). `vista_cdts` **incluye los CDT cerrados** con `tiempo_restante = "Cerrado"`. `fecha_cierre` = `YYYY-MM-DD`.
* **D1 (fórmula de interés):** hoy es **E.A. estricta** `(1+tasa)^(días/365)−1`, centralizada en una sola función de la BD; si el equipo elige otra convención solo cambia la BD (las tasas del front se muestran como % E.A.).
* **D11 (catálogo de CDT):** la BD no trae un catálogo; `listar_cdt_definiciones` devuelve `[]` hasta que el equipo decida los CDT y se cargue el seed (E14).
* **D-E7-5 / D6:** el `total` incluye los CDT activos.

Notas:
* Sin idempotencia: un doble clic en «Abrir CDT» = dos CDT (cada uno atómico). Evita reenvíos automáticos.
* Los créditos (E8–E9) aún no existen: `vista_balance` no resta deuda.
