# Backend — Banco Digital

Express + TypeScript. **Sin lógica de negocio**: cada endpoint hace una llamada a una función de PostgreSQL con el `usuario_id` de la sesión. Spec: `docs/specs`, plan: Tasks 10–11.

## Correr
```
npm i && npm run dev          # necesita DATABASE_URL y JWT_SECRET (ver ../.env.example)
npm test                      # unitarios con BD falsa (no necesita Docker)
RUN_OUTAGE=1 npx vitest run outage   # FIX 9 con docker compose real (stop/start db)
```
Escucha en el puerto 3000 (nginx del front hace proxy de `/api`). `Dockerfile.backend` usa `backend/` como contexto.

## Reglas
- `P0001` → 400 con el mensaje de la BD (`Recurso no encontrado` y `Acceso denegado` → 403). Cualquier otro error → 503 `{error:"sin_conexion"}`.
- Sesión: JWT en cookie httpOnly/lax; `validar_sesion` en cada petición (bloqueo inmediato). `COOKIE_SECURE=true` solo con HTTPS.
- Login: bcrypt en Node, 5 intentos fallidos/15 min por IP y por usuario → 429.
- Todas las funciones invocables están en `WHITELIST` (`src/db.ts`).

## Supuestos / desviaciones (revisar)
1. **SQLSTATE clase 22 y 23** (UUID inválido, violación de restricción) → **400 "Solicitud inválida"** y no 503: si no, un UUID mal escrito en la URL mostraría "estamos trabajando para solucionarlo". Desvía de la regla literal "todo lo demás = 503".
2. `COOKIE_SECURE` es una variable aparte de `NODE_ENV`: con `NODE_ENV=production` sobre `http://localhost` una cookie `secure` no se guardaría y el login fallaría en la demo.
3. `POST /creditos/simular` solo renombra campos de la BD (`cuota`→`cuota_mensual`, `total_pagar`→`total_a_pagar`).
4. `tipo` de transacción y unidad de tasas: se pasan **tal cual** vienen de la BD (pendiente acordar, ver prompt §6).
5. `/auth/reenviar` asume que `vista_perfil` incluye `correo`. El front aún no tiene pantalla `/verificar`.
6. `RESEND_ENABLED=false` por defecto (bono de referido se paga al registrar).

## Huecos: funciones que la BD debe crear (ya en la whitelist; los endpoints devuelven 503 hasta entonces)
| Función | Endpoint |
|---|---|
| `vista_balance(p_usuario_id)` → `{total, principal, bolsillos:[{id,nombre,saldo}]}` | `GET /api/bolsillos` |
| `renombrar_bolsillo(p_usuario_id, p_bolsillo_id, p_nombre)` | `PATCH /api/bolsillos/:id` |
| `listar_cdt_definiciones()` → `id, nombre, tasa, plazo_dias, monto_min` | `GET /api/cdts/definiciones` |
| `productos_publicos()` (sin usuario) → `id, nombre, descripcion, tasa, monto_min, monto_max, plazo_min, plazo_max` | `GET /api/creditos/productos` |
| `admin_get_reloj(p_admin_id)` → jsonb `{usar_fecha_real, fecha_sistema, fecha_actual}` | `GET /api/admin/reloj` |
| `admin_get_tasas(p_admin_id)` → jsonb `{cdts[], creditos[], mora}` | `GET /api/admin/tasas` |
| `admin_ajustar_balance` debe aceptar el identificador que manda el front (id o username) | `POST /api/admin/balance` |

Funciones `jsonb` se leen como `rows[0][nombre_funcion]`; las `TABLE(...)` devuelven filas tal cual.

## Pendiente
Integración contra Postgres real (no existe `db/` ni `docker-compose.yml` en el repo todavía).
