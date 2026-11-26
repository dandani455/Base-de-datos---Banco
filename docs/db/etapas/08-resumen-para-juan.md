# Etapa 8 — Créditos · resumen para el backend (Juan)

Cinco funciones nuevas; las de cliente reciben `p_usuario_id` (el de la sesión) y todas devuelven **`jsonb`**. Los errores de negocio llegan como `P0001` con el mensaje exacto → responde **400** con ese texto (`Recurso no encontrado` → **403**, como en E5–E7). Cualquier otro error sigue siendo 503.

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `GET /creditos/productos` (con sesión) | `SELECT productos_disponibles($1 /*usuario_id*/)` | `[{ id, nombre, tasa, monto_min, monto_max, plazo_min, plazo_max }]` con los **topes efectivos del usuario** (`[]` si no hay catálogo) |
| `GET /creditos/productos` (**landing, sin sesión**) | `SELECT productos_publicos()` | `[{ id, nombre, descripcion, tasa, monto_min, monto_max, plazo_min, plazo_max }]` con topes **base** (sin datos personales). *Decisión tuya:* el contrato (§7.3) deja abierto si se expone. |
| `POST /creditos/simular` `{producto_id, monto, plazo}` | `SELECT simular_credito($1, $2 /*producto_id, texto*/, $3 /*monto como TEXTO*/, $4 /*plazo en meses, numérico*/)` | `{ cuota_mensual, total_a_pagar, intereses_totales }` |
| `POST /creditos` `{producto_id, monto, plazo}` | `SELECT solicitar_credito($1, $2, $3, $4)` (mismos parámetros) | `{ id, fecha }` (`id` = id del crédito). Desembolso **instantáneo** |
| `GET /creditos/mis-creditos` | `SELECT vista_creditos($1)` | `[{ id, producto, cuotas_pagadas, cuotas_faltantes, interes_mes, saldo }]` (solo créditos **vigentes**; `[]` si no hay) |

**Qué NO existe todavía (E9):** `POST /creditos/:id/abono` (el botón «Abonar a capital» del front no tiene función de BD detrás hasta E9), pagar cuota, mora y descuento automático. `vista_creditos` no trae aún `descuento_automatico` ni `mora_acumulada` (los «opcionales futuros» del contrato).

Reglas para el backend (las mismas de E5–E7, más una):
* **Ids como texto**: `producto_id` va tal cual (texto); un uuid mal formado lo responde la BD como `Recurso no encontrado` (no un 503 del driver).
* **Monto como texto** (`'10000000'`), no `float`: un `0.30000000000000004` da `Monto inválido`.
* **Plazo como número tal cual lo manda el front** (no lo conviertas a `int` en el driver): un `12.5` o un `0` lo rechaza la BD con `Plazo fuera de rango`; si el driver intentara un entero fallaría como 503.
* El front no lee la salida de `solicitar_credito` (basta 200); recarga con `GET /creditos/mis-creditos`, `GET /bolsillos` y `GET /dashboard`.
* Sin idempotencia: un doble clic = la segunda petición responde `Ya tienes un crédito vigente de este producto` (un crédito vigente por producto).

Mensajes (**todos del contrato §6; ninguno inventado**):

| Situación | Mensaje |
|---|---|
| Producto mal formado o inexistente | `Recurso no encontrado` |
| Monto ≤ 0, > 2 decimales | `Monto inválido` |
| Monto fuera del rango o del tope efectivo del producto | `Monto fuera de rango` |
| Plazo fraccionario, ≤ 0 o fuera de [mínimo, máximo del producto] | `Plazo fuera de rango` |
| Plazo dentro del producto pero mayor que `(70 − edad) × 12` (solo Inmuebles) | `Plazo excede el límite de edad` |
| Segundo crédito vivo del mismo producto | `Ya tienes un crédito vigente de este producto` |
| Sesión / bloqueo / admin | los de E4 |

Qué cambia en lo que ya usabas: nada de contrato. Como en E7, **leer puede escribir**: la primera llamada tras un salto de reloj devenga los intereses de bolsillos y CDT antes de calcular los topes o leer.

Decisiones **provisionales** que te afectan (a confirmar con el front/equipo):
* **D10:** `simular_credito` recibe `p_usuario_id` (el contrato no lo lleva; hace falta para el tope de Inmuebles y la edad); `plazo` llega como `numeric`; `solicitar_credito` devuelve `{id, fecha}`.
* **D1 (fórmula):** la tasa del producto se trata como **efectiva anual** y la cuota francesa usa `i = (1+t)^(1/12) − 1` (con $10.000.000, 12 cuotas, 18 %: cuota **910.463,77**; con la tasa nominal 18/12 sería 916.799,93). Centralizado en `_tasa_mensual`; el contrato dice también «i = tasa/12»: contradicción abierta para el equipo.
* **D11 (catálogo):** la BD no trae productos; `productos_disponibles` y `productos_publicos` devuelven `[]` hasta que el equipo decida los 4 productos (nombres, montos, plazos, tasas) y se cargue el seed (E14).
* **D6:** `balance_total` / `total` de `GET /bolsillos` **no resta** la deuda: al desembolsar, el total mostrado sube en el monto del crédito. El tope de Inmuebles sí usa el patrimonio neto (activos − deuda), como define el spec §7.6.
* **D-E8-4:** `interes_mes` = interés devengado del período de la próxima cuota impaga, prorrateado por días (se confirma con el front; contrato §7.4).
* Los vencimientos son mensuales (mismo día del mes, recortado a fin de mes) y la última cuota absorbe el redondeo.
* Los productos se listan **siempre**, aunque los topes efectivos queden en 0 (p. ej. Inmuebles con la cuenta vacía): el front mostrará «Monto $1 a $0».
