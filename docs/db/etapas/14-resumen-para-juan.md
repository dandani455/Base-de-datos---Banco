# Etapa 14 — Seed y QA · resumen para el backend y la integración

**Aviso:** el backend de `origin/main` es un borrador temporal y **no es fuente de autoridad**; esto describe **la BD terminada**. E14 **no agrega funciones ni endpoints**: `public` sigue con 131 funciones y `banco_app` con **40**. Lo nuevo es el **seed** (datos de prueba reales para integrar), el **respaldo/restauración** y el runbook ([runbook-demo.md](../runbook-demo.md)).

## Cómo tener la BD lista para integrar

```
db\ctl.cmd up
db\ctl.cmd reset -Yes ; db\ctl.cmd apply ; db\ctl.cmd seed        (catálogo + datos de demostración)
db\ctl.cmd backup inicial                                          (para repetir la demostración: restore inicial -Yes)
```

## Usuarios del seed (clave de todos: `Banco2026`; ficticios, solo demostración)

| Usuario | Rol / estado | Cuenta | Para qué sirve |
|---|---|---|---|
| `admin1` | ADMIN (**sin cuenta**) | — | panel admin, Control, reloj, tasas |
| `jperez483` | CLIENTE | `4001002003` | el cliente demo del contrato §5: bolsillos «Viajes» y «Emergencias», 2 CDT (1 activo, 1 cerrado), crédito *Libre inversión* (al día, descuento automático) y *Vehículo* (**con mora**), > 20 envíos/recibos; código de referido fijo `8f3c2a10-5b7e-4d3a-9c21-6a7b1d0e42f9` |
| `cgomez12` | CLIENTE | `4003004005` | segundo cliente (bolsillo «Ahorro») |
| `bloqueado1` | CLIENTE **BLOQUEADO** | `4005006007` | probar el mensaje de bloqueo |
| `amora271`, `lospina604`, `sgomez118`, `farango352`, `pvargas907`, `vcastano445`, `sherrera630`, `dtorres219` | CLIENTE | `40…` | contrapartes para transferencias (`dtorres219` fue referida por `jperez483`: pagó el bono) |

* **Login:** `obtener_credenciales('jperez483')` devuelve el hash bcrypt de `Banco2026` (cost 10); el backend lo compara como siempre. **`admin1` no tiene `numero_cuenta`** (el mock sí le inventaba uno; el modelo de BD no da cuenta al ADMIN).
* El seed termina con el reloj en **modo real** (`usar_fecha_real = true`), sin movimientos en el futuro, y con lo guardado **al día** (`sp_avanzar_todos`): lo que vea Control coincide con lo que calculan las funciones.
* **Montos y fechas:** los ingresos iniciales son aleatorios pero **reproducibles** (misma siembra = mismos montos); los UUID cambian. Los números del mock (p. ej. «11 cuotas pagadas») **no coinciden**: el seed los produce con las reglas reales.

## Catálogo (D11, **provisional del equipo**, editable en `db/seed/00_catalogo.sql`)

* **Créditos** (reglas del spec §7.6, tasas del mock): *Libre inversión* (tope $30M, hasta 24 m, 23,9 %), *Vehículo* ($50M–$200M, hasta 120 m, 18,9 %), *Educación* ($1M–$100M, hasta 240 m, 15,4 %), *Inmuebles* (hasta 360 m, 100× patrimonio con tope $2.000M, regla de edad, 14,1 %). **Los nombres siguen al spec** («Educación», «Inmuebles»); el mock decía «Educativo», «Vivienda».
* **CDT:** 90, 180 y 360 días al 9,25 / 10 / 10,75 % E.A., mínimo $100.000 (el mock decía 500.000 / 1M / 2M).
* **Mora = 30 %** solo en el seed (D-E14-D3; D7 sigue abierta).

## Para el front (mock desactualizado, sin tocar)

* Con el catálogo del spec, un crédito de **Vehículo** no puede ser menor de $50M (el mock mostraba uno de $12M).
* Las páginas de Control son de **50** filas y el error de tabla es `Tabla no permitida` (E12).

## Pendiente de coordinar

* **Jose (Docker):** hoy `apply` y `seed` se ejecutan a mano con `ctl`; cómo correrlos en `docker compose up` es una decisión del Compose final (la BD no ejecuta nada sola al arrancar).
* **Juan/Daniel García:** el e2e con navegador y el banner de «sin conexión» (503) dependen del backend; la BD ya cumple su parte (datos persistentes, sin pasos extra al volver).
