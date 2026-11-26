# QA — Banco Digital

`qa/e2e.sh` prueba el stack completo por HTTP a través de nginx, como lo usa el navegador. Verifica el status y la **forma** de cada respuesta frente a lo que el front espera ([front/src/api/types.ts](../front/src/api/types.ts)) y el contrato de la BD ([docs/db/etapas/10-resumen-para-juan.md](../docs/db/etapas/10-resumen-para-juan.md)). Cómo correrlo: [docs/runbook-stack.md](../docs/runbook-stack.md#2-qa-de-punta-a-punta).

## Resultado actual — 2026-11-26 (BD recién creada, `SEED=demo`, backend integrado)

**58 passed, 0 failed** (`qa/e2e.sh --apagon`).

| Área | Resultado |
|---|---|
| Docker: `up` desde cero, init de BD (27 archivos + semilla), healthchecks, orden de arranque | ✅ |
| Apagón §10: BD caída → 503 `sin_conexion` en todo, backend vivo, front servido; vuelve sin reiniciar y con la misma sesión; backend caído → nginx da el mismo 503 | ✅ 8/8 |
| Registro (username autogenerado, nace con 5 ingresos), login, bloqueo con mensaje exacto, contraseñas débiles, duplicados | ✅ |
| Cliente: perfil, dashboard, historial, bolsillos, envíos, destinatario, CDTs (definiciones, simular, crear), créditos (productos, simular, un crédito vivo por producto) | ✅ |
| Admin: búsqueda, detalle, bloquear/desbloquear (con efecto inmediato en el login), ajuste de balance, reloj, tasas, Control (esquema y tablas, `password_hash` enmascarado, lista blanca) | ✅ |
| Seguridad §9: 401 sin sesión, 403 cliente→admin, 403 al operar un bolsillo ajeno | ✅ |
| Unitarias: backend 56 ✅ (1 omitida: apagón real), front 59 ✅ | ✅ |

## Historial

* **2026-11-25 — 33 passed, 14 failed.** El backend de `main` estaba escrito contra un contrato anterior a la BD terminada: leía filas donde la BD devuelve `jsonb` (panel admin entero en 403, registro sin username, listas envueltas) y llamaba funciones sin `p_usuario_id`. **Corregido el 2026-11-26**; el detalle de los cambios está en [backend/README.md](../backend/README.md#integración-con-la-bd-terminada-e10e14--2026-11-26). Las unitarias del backend ahora simulan la forma real de la BD (`backend/test/contrato.test.ts`).

## Pendiente

* **Renombrar bolsillo:** `renombrar_bolsillo` no existe en la BD; el endpoint se quitó (el front no lo usa).
* **Reenviar verificación:** `vista_perfil` no trae `correo`; solo importa con `RESEND_ENABLED=true`.
* **Ensayo en navegador:** recorrer las pantallas de §12 a mano (el E2E prueba la API que usan, no el dibujo).
* **Repetir todo cuando la BD cambie:** `docker/bd.sh recrear` y `qa/e2e.sh --apagon`.

## Notas

* La búsqueda de admin es por nombre, cédula, correo o número de cuenta (§7.7), **no** por username.
* `id` malformado en la URL → 403 «Recurso no encontrado» (lo decide la BD). No es 503: correcto para §10.
* Ruta de API inexistente sin sesión → 401 (el `requireSession` del router de cliente atrapa todo). Aceptable.
* No se corrió la suite SQL de la BD (`db/ctl.sh test`): ya tiene su evidencia en `docs/db/evidencias/`.
