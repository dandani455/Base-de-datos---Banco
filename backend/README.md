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
3. `RESEND_ENABLED=false` por defecto (bono de referido se paga al registrar).

## Integración con la BD terminada (E10–E14) — 2026-11-26
Contrato: [docs/db/etapas/10-resumen-para-juan.md](../docs/db/etapas/10-resumen-para-juan.md) (tabla maestra), 08, 09, 11 y 12.
* **Todas las funciones devuelven `jsonb`** (D3): se leen con `json(db, fn, args)` de `src/db.ts`, que desenvuelve `rows[0][fn]`. Solo `obtener_credenciales` (TABLE) y `verificar_correo` (void) usan `db.call`. Los endpoints responden el jsonb **tal cual** (también en las escrituras).
* **`p_usuario_id` / `p_admin_id` primero** en todas, incluidas `listar_cdt_definiciones`, `nombre_destinatario`, `simular_cdt` y `simular_credito` (esta ya devuelve `cuota_mensual`, `total_a_pagar`, `intereses_totales`: no se renombra nada).
* `requireSession` lee `{username, rol}` del jsonb de `validar_sesion`; `GET /yo` sale de ahí (no de `vista_perfil`: el ADMIN no tiene cuenta).
* `GET /creditos/productos`: con sesión → `productos_disponibles(usuario)` (topes del usuario y regla de edad); sin sesión (landing) → `productos_publicos()`.
* `GET /transacciones?limite=`: entero o `NULL` (= 50; la BD acota a [1, 50]). `GET /admin/tabla/:n?pagina=`: texto tal cual o `NULL`.
* `POST /creditos/:id/pagar-cuota` acepta `{numero}` opcional (idempotencia: `cuotas_pagadas + 1`).
* Verificado de punta a punta contra la BD real con `qa/e2e.sh --apagon`: 58/58 (ver [qa/README.md](../qa/README.md)).

## Pendiente
* **`PATCH /bolsillos/:id` (renombrar) se quitó**: `renombrar_bolsillo` no existe en la BD y el front no lo usa. Si se quiere, primero la BD.
* **`POST /auth/reenviar`** no envía nada: `vista_perfil` no trae `correo`. Solo importa con `RESEND_ENABLED=true` (y el front no tiene pantalla `/verificar`).
