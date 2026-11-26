# Etapa 13 — Mantenimiento · resumen para el backend

**Aviso:** el backend actual de `origin/main` es un borrador temporal y **no es fuente de autoridad**; este resumen describe **la BD terminada**. **E13 no tiene ningún endpoint ni función para el backend:** `sp_avanzar_todos` y `sp_verificar_integridad` son procedimientos de **administración** (`CALL`), **sin `EXECUTE` para `banco_app`**: la lista blanca del backend sigue en **40** funciones.

* **No cambia nada de lo que ya consume el backend.** El motor sigue siendo perezoso: cada función de cliente pone al día **su** cuenta antes de responder; no hace falta ningún proceso periódico para que las cifras sean correctas.
* **Qué hacen** (solo dueño / superusuario, p. ej. pgAdmin «administración (postgres)» o `ctl.sh psql`):
  * `CALL sp_avanzar_todos();` pone al día **todas** las cuentas (intereses, cierres de CDT, cobros automáticos) con **una transacción por cuenta**; devuelve un resumen y escribe **un** evento de auditoría `MANTENIMIENTO_AVANZAR`. Es idempotente. Hay que llamarlo **solo**, en autocommit: dentro de `BEGIN … COMMIT` falla con `invalid transaction termination`.
  * `CALL sp_verificar_integridad();` devuelve un informe `jsonb` (`ok`, conteos y las filas defectuosas); solo lectura.
* **Si el backend quisiera programarlos** (cron, tarea del servidor): sería una conexión con **rol de administración**, nunca la de `banco_app`; es la decisión **D-E13-D1** del equipo (hoy: solo manual). La BD no trae planificador.
* **Consistencia mientras corre:** una cuenta ocupada más de 2 s se **omite** (`omitidas_por_timeout_de_bloqueo`) y se pone al día en su próxima operación; el backend no ve nada distinto (las operaciones normales esperan el bloqueo breve de la cuenta que se está cerrando, como siempre).
