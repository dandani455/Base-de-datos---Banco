# E4 — Resumen para Juan (backend): registro, login y sesión

**Estado (2026-11-23):** estas firmas están **implementadas y probadas** en la base (scripts `13_auth_utilidades.sql` y `14_auth_funciones.sql`), **a la espera de la auditoría del responsable de BD**. Sirve para que apuntes el backend y para pedirte **una confirmación** (sección 4). Las **reglas de edad/formato y los mensajes marcados *provisional*** siguen pendientes de decisión del equipo (D12b/D13) y están centralizados: pueden cambiar sin cambiar la forma de las respuestas. Detalle: [04-auth.md](04-auth.md) y [04-auth-diseno.md](04-auth-diseno.md). Contrato: `2026-11-18-contrato-bd-front.pdf`.

**Cómo probarlo tú mismo (sin Docker del backend):** `db\ctl.cmd up`, `db\ctl.cmd apply` y, con la conexión `banco_app` (contraseña de desarrollo en `db/sql/01_roles.sql`), `SELECT public.registrar_usuario(...)`. La prueba `db/tests/reales/39_auth_conexiones.sh` hace exactamente la conversación del backend con conexiones TCP reales de `banco_app`.

## 1. Firmas definitivas (todas `SECURITY DEFINER`; `banco_app` solo tiene `EXECUTE`)

| Endpoint | Llamada | Devuelve |
|---|---|---|
| `POST /auth/registro` | `SELECT registrar_usuario($1,…,$10)` | 1 fila, columna `jsonb` `{ "usuario_id": uuid, "username": text }` |
| `POST /auth/login` (1.º) | `SELECT * FROM obtener_credenciales($1)` | **0 filas** si el usuario no existe; si existe: `usuario_id, password_hash, rol, estado` |
| `POST /auth/login` (3.º) y **cada petición** | `SELECT validar_sesion($1)` | `jsonb` `{ "username", "rol", "estado" }`; **lanza** el mensaje de bloqueo si está bloqueado |
| `GET /yo` | `SELECT validar_sesion($1)` | `{ username, rol }` (el front exige `rol`) |
| `GET /perfil` | `SELECT vista_perfil($1)` | `jsonb` `{ "username", "numero_cuenta" (10 dígitos, string), "codigo_referido" (uuid) }` |
| verificación de correo (enlace) | `SELECT verificar_correo($1)` | `void`; idempotente (no paga dos veces el bono) |

`registrar_usuario(p_nombres text, p_apellidos text, p_cedula text, p_correo text, p_telefono text, p_fecha_nacimiento text, p_password_hash text, p_acepta_politica boolean, p_codigo_referido text, p_verificacion_activa boolean)` — **en ese orden**.

## 2. Dos parámetros son `text` (no `date` ni `uuid`)
* **`p_fecha_nacimiento`**: pásalo tal cual llega del front (`"YYYY-MM-DD"`).
* **`p_codigo_referido`**: pasa el `codigo_referido` del body **tal cual** (puede venir ausente → `NULL`, o ser basura del `?ref=` de la URL). **No lo conviertas a uuid**: si es inválido la BD responde el error de negocio `Código de referido inválido`; un cast fallido en el driver sería un 503.
* Regla general: **todo error de negocio llega como `P0001`** → tu 400 con el mensaje **tal cual**.

## 3. Flujo de bcrypt y de sesión
**Registro**
1. El backend valida la política de contraseña (mín. 8, 1 mayúscula, 1 número); la BD **no** la ve.
2. `bcrypt.hash(password)` (coste 10–12). El hash debe tener forma `$2a$/$2b$/$2y$NN$` + 53 caracteres (60 en total): **la BD rechaza cualquier otra cosa** (para no guardar nunca una clave en claro).
3. `registrar_usuario(..., p_password_hash = hash, p_acepta_politica, p_codigo_referido, p_verificacion_activa = (RESEND_ENABLED === 'true'))`.
4. Si la verificación está activa: envía el correo con un token firmado por ti que lleve `usuario_id`.
5. **Responde al front solo `{ "username": ... }`** (no devuelvas `usuario_id`).

**Login**
1. `obtener_credenciales(username)`. **0 filas** → haz igualmente un `bcrypt.compare` contra un hash señuelo (igualar tiempos) y responde **400 `Credenciales inválidas`**.
2. Con 1 fila: `bcrypt.compare(password, password_hash)`. Si falla → **la misma** respuesta `Credenciales inválidas` (idéntica para usuario inexistente y clave mala).
3. **Solo si la clave es correcta**: `validar_sesion(usuario_id)`. Si el usuario está bloqueado lanza `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla` (así el estado de un tercero nunca se revela sin la clave).
4. Firma el JWT (cookie httpOnly) y responde `{ username, rol }`.

**Cada petición autenticada:** `validar_sesion(usuario_id_del_token)` (estado y rol **vivos**; bloquear con sesión abierta surte efecto en la siguiente petición). Si el usuario ya no existe, la BD lanza `Sesión inválida` (mensaje provisional).

Aislamiento: el `READ COMMITTED` por defecto de `pg` (el libro lo exige).

## 4. ⏳ Confirmación pendiente (necesito tu respuesta)
**¿Vas a implementar `POST /auth/reenviar` (reenvío del correo de verificación)?**
* **Sí** → añadiré una sexta función pública `datos_reenvio_verificacion(p_username text)` → `TABLE(usuario_id uuid, correo text)` (0 filas si el usuario no existe **o** ya está verificado; nunca lanza). Identifica por `username` (el usuario no tiene sesión), y tu respuesta debe ser **idéntica** exista o no el usuario. Tú generas el token y envías el correo.
* **No** → la función **no se crea** y `banco_app` queda con solo 5 funciones.

## 5. Diferencias entre el mock y el contrato (lo relativo a esta etapa)
| Tema | Mock (`front/mock/server.mjs`) | Contrato / BD (manda) |
|---|---|---|
| Registro: mensajes | `Falta el campo X`, `Ya existe un usuario con esa cédula` | `Debe aceptar la política de datos` (contrato) y mensajes nuevos **provisionales**: `La cédula ya está registrada`, `El correo ya está registrado`, `El teléfono ya está registrado`, `Código de referido inválido`, `Debes ser mayor de edad para registrarte`, `Cédula/Teléfono/Correo/Nombre/Apellido inválido(a)`, `Fecha de nacimiento inválida`, `Datos de registro incompletos` |
| Username | `inicial+apellido+3 dígitos` con `normalize` propio | `inicial + primer apellido` (sin tildes, sin partículas) + **3–4 dígitos**, único (la BD lo genera) |
| `GET /yo` | `{ username, rol }` ✅ | igual; `Yo.rol?` es opcional en `types.ts` pero la BD **siempre** lo entrega |
| Login bloqueado | mensaje exacto ✅ | igual, pero solo **después** de la clave correcta |
| Validaciones | el mock no valida edad, teléfono, cédula ni referido | las valida la BD (provisional hasta que el equipo decida D12b/D13) |
| Fuera de esta etapa (para tu información) | tasas como fracción, ids enteros, nombres de producto | el contrato manda (ver §2 y §5 del PDF) |

## 6. Notas
* Todas las reglas de edad/formato/mensajes marcadas *provisional* están **centralizadas** y pueden cambiar cuando el equipo decida D12b/D13; la **forma** de las respuestas no cambia.
* El registro tarda ≈ 35 ms (5 asientos de ingreso incluidos).
* La BD no hace rate limit ni envía correos: eso es del backend.
