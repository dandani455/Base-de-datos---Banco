# Etapa 6 — Bolsillos · resumen para el backend (Juan)

Cinco funciones nuevas; todas reciben `p_usuario_id` (el de la sesión) y devuelven **`jsonb`**. Los errores de negocio llegan como `P0001` con el mensaje exacto → responde **400** con ese texto (`Recurso no encontrado` → **403**). Cualquier otro error sigue siendo 503.

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `GET /bolsillos` | `SELECT vista_balance($1 /*usuario_id*/)` | `{ total, principal, bolsillos: [{ id, nombre, saldo }] }` — pásalo tal cual |
| `POST /bolsillos` `{nombre}` | `SELECT crear_bolsillo($1, $2 /*nombre tal cual lo escribió el usuario*/)` | `{ id, nombre }` |
| `POST /bolsillos/:id/ingresar` `{monto}` | `SELECT mover_a_bolsillo($1, $2 /*:id, texto*/, $3 /*monto como TEXTO*/)` | `{ id, fecha }` (cuenta → bolsillo) |
| `POST /bolsillos/:id/retirar` `{monto}` | `SELECT retirar_de_bolsillo($1, $2 /*:id*/, $3 /*monto TEXTO*/)` | `{ id, fecha }` (bolsillo → cuenta) |
| `POST /bolsillos/:id/mover` `{monto, destino_id}` | `SELECT mover_entre_bolsillos($1, $2 /*:id origen*/, $3 /*destino_id*/, $4 /*monto TEXTO*/)` | `{ id, fecha }` |

Reglas para el backend (las mismas de E5):
* **Ids como texto**: no los conviertas a `uuid` (un uuid mal formado daría 503; la BD lo responde como `Recurso no encontrado`). Los ids que entrega `vista_balance` se usan tal cual en `:id` y en `destino_id`.
* **Monto como texto** (`'150000.50'`), no `float`: un `0.30000000000000004` da `Monto inválido`.
* El front no lee las salidas de las operaciones (basta 200); recarga con `GET /bolsillos`.

Mensajes: `Monto inválido`, `Recurso no encontrado` (bolsillo mal formado, inexistente o de otra cuenta), `Saldo insuficiente`, los de sesión de E4 (`Sesión inválida`, `Acceso denegado`, mensaje de bloqueo) y dos **nuevos y provisionales** (a confirmar con el front, D13): `Nombre de bolsillo inválido` (nombre vacío, de más de 40 caracteres o con caracteres de control) y `Los bolsillos de origen y destino deben ser distintos` (el front no puede enviarlo: filtra `otros`).

Notas:
* La tabla del contrato §3.3 sale ilegible en el PDF; las entradas se tomaron de `Balance.tsx` y del texto del contrato (`ingresar {monto}`, `retirar {monto}`, `mover {monto, destino_id}`). Si `retirar` debe aceptar un `destino_id`, avísanos.
* `total` es **provisional** (D6 pendiente): hoy = cuenta principal + bolsillos. Cuando el equipo decida cómo cuentan CDT y créditos, solo cambia la BD; el contrato de la respuesta no cambia.
* Sin idempotencia: un doble clic = dos movimientos (cada uno atómico). Evita reenvíos automáticos.
* El interés de los bolsillos (12 %) llega en E7: hasta entonces los saldos no devengan.
