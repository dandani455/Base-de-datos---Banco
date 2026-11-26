# Etapa 9 — Pagos, abonos, mora y descuento automático · resumen para el backend (Juan)

Tres funciones públicas nuevas (todas con `p_usuario_id` = el de la sesión, todas devuelven **`jsonb`**) y una función ya existente que gana dos campos. Los errores de negocio llegan como `P0001` con el mensaje exacto → responde **400** con ese texto (`Recurso no encontrado` → **403**, como en E5–E8). Cualquier otro error sigue siendo 503.

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `POST /creditos/:id/abono` `{monto}` (**ya está en el contrato**) | `SELECT abonar_credito($1 /*usuario_id*/, $2 /*id del crédito, TEXTO*/, $3 /*monto como TEXTO*/)` | `{ fecha, mora, interes, capital, saldo, cuota_nueva }` (el front **no la lee**: basta 200; recarga con `GET /creditos/mis-creditos`, `GET /dashboard`, `GET /bolsillos`) |
| *(sin endpoint en el contrato)* pagar la próxima cuota | `SELECT pagar_cuota($1, $2 /*id del crédito*/, $3 /*numero, opcional*/)` | `{ numero, pagado, mora, fecha }` |
| *(sin endpoint en el contrato; el plan menciona `POST /creditos/:id/descuento`)* activar/desactivar el descuento automático | `SELECT activar_descuento_automatico($1, $2, $3 /*boolean*/)` | `{ id, descuento_automatico }` |
| `GET /creditos/mis-creditos` (E8, ampliada) | `SELECT vista_creditos($1)` | los 6 campos de siempre **+ `descuento_automatico` (bool) y `mora_acumulada` (number)** — los «opcionales futuros» del contrato; el front puede ignorarlos |

**Qué hace cada una**
* **`pagar_cuota`** paga la **próxima cuota impaga completa** (no hay pagos parciales ni se salta una cuota), por adelantado si hace falta, desde la cuenta principal. Importe = `valor_cuota` + mora de esa cuota a hoy (0 si no está vencida o si no hay tasa de mora). **`numero` es opcional y sirve de idempotencia:** si lo mandas y esa cuota ya está pagada (o no es la próxima), responde `Recurso no encontrado` y **no paga otra**; sin `numero`, dos llamadas pagan dos cuotas consecutivas. Recomendación: manda `numero` (el de `cuotas_pagadas + 1`) para que un doble clic o un reintento no cobren dos veces.
* **`abonar_credito`**: el abono cubre primero la **mora vencida**, luego el **interés corriendo** del período y el resto baja **capital**; las cuotas restantes se recalculan con **el mismo plazo y los mismos vencimientos** (cuota menor). Un abono que no alcanza a bajar capital, o que supera la deuda de liquidación, responde `Monto fuera de rango`. Si el abono es exactamente la liquidación, el crédito queda `PAGADO` y desaparece de `vista_creditos`. Sin idempotencia: dos abonos son dos abonos.
* **`activar_descuento_automatico`**: con el descuento activo, **cualquier lectura u operación del cliente** cobra sola las cuotas vencidas cuando hay saldo en la cuenta principal (todo o nada, en orden cronológico; el dinero de CDT que vence se cuenta primero). Activar **no es retroactivo**: lo vencido antes de activar se cobra en la primera ronda posterior. Activarlo dos veces no hace nada; desactivarlo lo apaga.

**Reglas para el backend** (las mismas de E5–E8, más tres)
* **Ids como texto** (`credito_id` va tal cual; uno mal formado lo responde la BD como `Recurso no encontrado`, no un 503 del driver). **Monto como texto** (`'500000'`), no `float`: un `0.30000000000000004` da `Monto inválido`.
* **El historial se ordena por `orden`, no por `fecha`.** Un cobro automático se fecha en el día en que **debió** ocurrir (p. ej. el día en que venció el CDT que lo financió), igual que los cierres de CDT de E7: puede quedar con fecha anterior a movimientos posteriores del mismo usuario.
* **Leer puede escribir más que antes:** la primera lectura tras un salto de reloj puede cobrar cuotas (además de intereses y cierres de CDT). 360 cuotas ≈ 1,7 s.
* El front **no tiene UI** para pagar cuota ni para el descuento; el único botón de E9 en pantalla es «Abonar a capital».

Mensajes (**todos del contrato §6; ninguno inventado**):

| Situación | Mensaje |
|---|---|
| Crédito ajeno, inexistente, mal formado o ya `PAGADO`; `numero` ya pagado o que no es el próximo | `Recurso no encontrado` |
| Monto ≤ 0, > 2 decimales | `Monto inválido` |
| Abono que no baja capital o que supera la liquidación | `Monto fuera de rango` |
| La cuenta principal no alcanza para la cuota (+ mora) o para el abono | `Saldo insuficiente` (no se escribe nada) |
| Sesión / bloqueo / admin | los de E4 |

Decisiones **provisionales** que te afectan (a confirmar con el equipo/front):
* **D7 (mora, abono, cobro):** la mora es **derivada** (no se escribe al pasar el tiempo) y **simple sobre el valor de la cuota**: `valor × tasa_mora_anual/100/365 × días`. **`parametro.tasa_mora_anual` no tiene valor** hasta que el equipo decida: con NULL la mora es **0** (el admin la fijará con `admin_set_tasa_mora`, E11). Se **cobra al pagar** (grupo aparte) y en el abono.
* **D10 (firmas):** las tres funciones y sus respuestas son propuestas de BD; `pagar_cuota` y el descuento **no están en el contrato**: exponerlos es decisión tuya y del front.
* **D1 (tasas):** el recálculo tras un abono usa la misma convención E.A. de E8 (`_tasa_mensual`).
* El interés **no se devuelve** por pagar una cuota antes de su vencimiento (el mecanismo para pagar menos interés es el abono).
* Con el reloj del admin de vuelta a modo real por detrás de lo simulado, el cobro automático se **pausa** hasta que el calendario alcance el cursor; `pagar_cuota`, `abonar_credito` y desactivar el descuento siguen funcionando.
