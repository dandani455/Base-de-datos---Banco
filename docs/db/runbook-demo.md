# Runbook de la demostración — parte de base de datos (E14)

Cubre solo la **BD** (Docker `db` + pgAdmin). El backend, el front y el banner «sin conexión» son de Juan, Daniel García y Jose; este runbook deja la BD en el estado que ellos necesitan. Todo con `db\ctl.cmd` (Windows; no requiere Bash). **Los datos son ficticios y la clave `Banco2026` es solo de demostración.**

## 1. Preparar (una vez, antes de la demostración)

| # | Paso | Comando | Debe verse |
|---|---|---|---|
| 1 | Docker Desktop corriendo; levantar | `db\ctl.cmd up` | `PostgreSQL: LISTO`; pgAdmin en `http://localhost:5050` |
| 2 | Banco vacío y esquema | `db\ctl.cmd reset -Yes` y `db\ctl.cmd apply` | `Listo: 27 archivo(s)…` |
| 3 | Catálogo + seed | `db\ctl.cmd seed` | `== Seed completo. Esquema seed eliminado.` y una fila con `integridad_ok = t`, `reloj_real = t`, 12 usuarios, 1 CDT activo y 1 cerrado, 2 créditos |
| 4 | **Respaldo del estado inicial** | `db\ctl.cmd backup inicial` | `db\backups\banco_inicial.dump` (+ `.huella`) |
| 5 | Verificar en pgAdmin | conexión «Banco — administración» → `banco` → Query Tool | `SELECT * FROM v_reloj_estado;` → `usar_fecha_real = t`, `banco_vacio = f`, `patas_fechadas_en_el_futuro = 0`; `SELECT ok FROM v_integridad_global;` → `t` |

`ctl seed catalogo` carga **solo** el catálogo (3 CDT y 4 productos de crédito; idempotente; valores provisionales D11) en cualquier banco. `ctl seed demo` (= `seed`) exige un banco **vacío** (si no, se niega y no cambia nada).

**Usuarios del seed** (clave `Banco2026`): `admin1` (ADMIN, sin cuenta), `jperez483` (cuenta `4001002003`; 2 bolsillos, CDT activo y cerrado, crédito *Libre inversión* al día y *Vehículo* **con mora**), `cgomez12` (`4003004005`), `bloqueado1` (`4005006007`, bloqueado) y 8 clientes más (`amora271`, `lospina604`, `sgomez118`, `farango352`, `pvargas907`, `vcastano445`, `sherrera630`, `dtorres219`, esta última referida por `jperez483`).

## 2. Demostrar el paso del tiempo (política de E3: **un solo adelanto**)

1. Partir del estado inicial (paso 4) y, con el backend detenido, comprobar el punto 5.
2. **Un único** adelanto del reloj: como administrador (`PUT /admin/reloj`) o en pgAdmin: `SELECT admin_set_reloj('<uuid de admin1>', false, '2027-03-01');`.
3. Operar y mostrar: intereses de bolsillos y CDT, el CDT activo que vence, cuotas con descuento automático, la **mora** del crédito *Vehículo*, el abono (`abonar_credito`), etc.
4. Para que el visor **Control** y pgAdmin muestren lo **guardado** al día: `CALL sp_avanzar_todos();` (se ejecuta **sola**, en autocommit; ver E13).
5. (Opcional) volver a modo real; lo ocurrido permanece.

## 3. Repetir la demostración (restaurar)

1. Detener el backend (cierra su *pool*); pgAdmin se desconecta solo.
2. `db\ctl.cmd restore inicial -Yes` → valida el archivo y su manifiesto, restaura en una BD de paso, **verifica la huella y la integridad** y solo entonces la intercambia por `banco`. **La BD anterior queda como `banco_previo`** (vuelta atrás inmediata); `db\ctl.cmd descartar-previo` la elimina cuando ya no se necesita.
3. Verificar de nuevo el punto 5 del apartado 1 y reconectar pgAdmin (clic derecho → *Refresh*).

**Protecciones del respaldo/restauración:**
* `backup` **rechaza** una BD con `v_integridad_global.ok = false` (no se respalda un estado dañado) y una BD que cambie mientras se respalda; el manifiesto trae una **huella por tabla** (todas las columnas de las 11 tablas y de `audit.evento`) y la del esquema (permisos de funciones y triggers).
* `restore` exige `-Yes`; valida el archivo, que sea de este banco y que el manifiesto declare integridad ok; restaura en una BD de paso y **exige integridad verdadera** en ella y que **cada tabla coincida** con el manifiesto (si no, nombra la tabla y no toca `banco`); nunca actúa sobre `banco_test`; restaura solo en el **mismo clúster** (los roles `banco_*` son globales y no viajan en el volcado).
* **Intercambio seguro:** `banco` → `banco_retirada`, paso → `banco`, y solo al final la retirada pasa a `banco_previo` (el `_previo` anterior se conserva hasta ese último paso). Ante un error o una señal (HUP, INT, TERM) se recupera sola.
* **Si el proceso se corta de golpe** (cierre de la ventana, `kill -9`) y `banco` no existe o queda `banco_retirada`: `dbctl.cmd recuperar` (idempotente) devuelve la BD anterior o termina el intercambio; repetir el `restore` también lo hace al empezar.

## 4. Apagón de la BD (lo que la BD debe cumplir)

| Paso | Comando | Debe ocurrir |
|---|---|---|
| Caída | `docker compose -f db\compose.dev.yml --env-file db\.env stop db` | El backend recibe errores de conexión → **503** (lo implementa el backend; la BD no tiene que hacer nada) |
| Regreso | `docker compose -f db\compose.dev.yml --env-file db\.env start db` | `PostgreSQL: LISTO`; **los datos siguen** (volumen `pgdata`) y `v_integridad_global.ok = t`; sin pasos extra |
| **No** usar | `ctl down -Purge` o `docker compose down -v` | Borra el volumen: habría que repetir el apartado 1 |

## 5. Si algo sale mal

* **El seed falló a mitad:** la historia es **una sola transacción** (no queda nada) y el esquema temporal `seed` se elimina siempre; basta reintentar (`ctl seed`). Si el banco ya tenía datos: `ctl reset -Yes`, `ctl apply`, `ctl seed`.
* **La restauración dice que hay conexiones:** detener el backend/pgAdmin y repetir.
* * **`restore` se interrumpió y `banco` no aparece:** `dbctl.cmd recuperar`.
* **Una prueba de tiempo falla cerca de medianoche (hora de Bogotá):** repetirla.
* **Contraseñas del sistema:** `db\.env` (no versionado); los roles de aplicación de desarrollo están en `docs\db\00-entorno.md`.
