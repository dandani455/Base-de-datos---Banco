# Etapa 4 — Autenticación y registro de usuarios · DISEÑO TÉCNICO (versión revisada, para aprobación final)

> **ACTUALIZACIÓN — IMPLEMENTADO (2026-11-23).** E4 se implementó conforme a este diseño y su paquete de entrega vigente es [04-auth.md](04-auth.md) (scripts `13` y `14`, pruebas `40`–`48` y `reales/39`–`40`, mutaciones M51–M91, evidencias). **Desviaciones respecto de este texto** (detalle y justificación en la sección 10 de `04-auth.md`): (1) se añadió la función interna `_nombre_valido()` (13 internas, **47** funciones en total, no 46) porque `[[:alpha:]]` acepta dígitos no ASCII en esta configuración regional; (2) `nombre_min` es **1** (no 2): existen apellidos de un solo carácter (p. ej. 王); (3) `v_integridad_global.ok` incorpora `v_integridad_auth` y se agregó la columna `controles_auth_fallidos` al final; (4) `datos_reenvio_verificacion` **no se implementó** (D-E4-9 sigue pendiente de Juan): `banco_app` ejecuta 5 funciones; (5) la regla B del username conserva el respaldo `u`/`usuario` del diseño aprobado, **confirmada por el responsable de BD el 2026-11-23**: el error controlado `No fue posible generar el usuario…` solo ocurre por agotamiento. El texto que sigue es el **diseño aprobado** y se conserva sin cambios.

**Estado (versión del diseño):** la arquitectura y las decisiones técnicas fueron **aprobadas por el responsable de BD (2026-11-22) con observaciones**, que esta versión incorpora. Sin commits. No se toca `front/`, backend ni archivos de otros integrantes. No se decide nada financiero pendiente.

Parte de: diseño consolidado v3, [E1](01-esquema.md), [E2](02-libro-mayor.md), [E3](03-reloj.md) (aprobadas) y tus reglas: **las funciones de negocio llaman `_reloj_instantanea()` UNA sola vez por operación y reutilizan su resultado**; todo lo que escribe el libro pasa por `_asentar_grupo`; las limitaciones del superusuario siguen documentadas.

## Registro de decisiones y de esta revisión

| Estado | Decisiones |
|---|---|
| ✅ **Aprobadas por el responsable de BD** (con las observaciones incorporadas abajo) | D-E4-1 a D-E4-8, D-E4-10 y D-E4-11 |
| ⏳ **Pendiente de confirmación de Juan (backend)** | **D-E4-9**: la sexta función pública `datos_reenvio_verificacion`. **No se implementa ni se concede `EXECUTE` hasta que Juan confirme que usará `POST /auth/reenviar`**; mientras tanto el diseño y las pruebas se describen con **5 funciones públicas** y la sexta queda marcada *condicional* |
| ⚠️ **Provisionales — decisiones del EQUIPO (D12b/D13), NO aprobadas colectivamente** | D-E4-12 a D-E4-20. Se conservan las recomendaciones como **valores provisionales centralizados en un único lugar** (sección 5.7). **D-E4-17 (enumeración de usuarios/duplicados) y D-E4-19 (bono a referidores bloqueados) son decisiones de NEGOCIO pendientes** |

Cambios de esta revisión (a petición tuya): **(1)** se separa la validación de nombres para **almacenar** de la regla para **generar el username** (5.2/5.3); **(2)** reglas específicas y `+` solo al inicio en teléfono, nunca en cédula (5.2); **(3)** `vista_perfil` sin `avanzar_hasta` queda como **desviación consciente del contrato** (sección 9); **(4)** `datos_reenvio_verificacion` condicionada a Juan; **(5)** fechas de los ingresos distintas, ascendentes y dentro de 90 días **por construcción**, no por azar (5.4); **(6)** pruebas de atomicidad con fallos inyectados incluso **después de escribir patas del libro** (sección 6 y 12); **(7)** valores provisionales centralizados (5.7); **(8)** resumen para Juan.

---

## 0. Resumen en una página

E4 entrega las **primeras funciones de negocio ejecutables por `banco_app`**: registrar un cliente (usuario + cuenta + 5 ingresos simulados + bono de referido), entregar credenciales para el login, validar la sesión en cada petición (con el mensaje exacto de bloqueo), verificar el correo (bono idempotente) y el perfil.

1. **Cinco funciones públicas** (`registrar_usuario`, `obtener_credenciales`, `validar_sesion`, `verificar_correo`, `vista_perfil`) **+ una condicional** (`datos_reenvio_verificacion`, solo si Juan confirma) y **doce internas** (`_validar_cliente`, `_validar_admin`, `_pagar_bono_referido`, nueve utilidades puras). Scripts `13` y `14`.
2. **Reloj:** solo `registrar_usuario` y `verificar_correo` necesitan fechas, y cada una llama `_reloj_instantanea()` **exactamente una vez** y pasa `hoy`/`ahora` hacia las internas (que **nunca** consultan el reloj ni `now()`). Una prueba de catálogo lo hace cumplir.
3. **Libro:** los 5 `INGRESO_SIMULADO` y el `BONO_REFERIDO` se escriben **solo** con `_asentar_grupo`; ni un `INSERT` directo en `transaccion`.
4. **Contrato del front:** respeta `POST /auth/registro → { username }`, `POST /auth/login` (hash + estado), `GET /yo → { username, rol }` y los dos mensajes del §6. **Desviaciones conscientes** (sección 9): fecha de nacimiento y código de referido como `text`; `vista_perfil` sin `avanzar_hasta`.
5. **Decisiones:** 11 técnicas (aprobadas; la 9 pendiente de Juan) y 9 del equipo (provisionales, centralizadas).
6. **Pruebas:** ≈ 465 aserciones SQL + ≈ 75 de conexiones reales y concurrencia con `banco_app` + ≈ 32 mutaciones.

---

## 1. Alcance

| Entra en E4 | No entra (su etapa) |
|---|---|
| `registrar_usuario` (usuario, cuenta, 5 `INGRESO_SIMULADO`, referido, bono si la verificación está apagada) | Bcrypt, JWT, cookie, rate limit, envío de correo (Resend): **backend** (Juan) |
| `obtener_credenciales`, `validar_sesion`, `vista_perfil` | `nombre_destinatario`, transferencias: **E5** |
| `verificar_correo`, `_pagar_bono_referido` (única implementación, idempotente) | Bolsillos E6, `avanzar_hasta`/CDT E7, créditos E8–E9, vistas del dashboard E10 |
| `datos_reenvio_verificacion` — **condicional a la confirmación de Juan** | — |
| `_validar_cliente`, `_validar_admin` (helpers que usarán E5–E12) | `admin_bloquear/desbloquear/borrar`, `trg_usuario_estado`, ajuste de saldo: **E11** (aquí solo se **lee** `estado`) |
| Endurecer `v_integridad_*` para el nuevo estado (`banco_app` ya tiene `EXECUTE`) y 2 controles nuevos | Admin inicial, usuarios fijos del seed (`jperez483`, `admin1`, `bloqueado1`, cuenta `4001002003`): **E14** (D5) |
| Pruebas, mutaciones, documentación, guía de pgAdmin | Recuperación de contraseña: fuera de alcance del spec (devuelve el genérico) |

---

## 2. Requisitos y fuentes

| Fuente | Qué exige |
|---|---|
| Spec §7.1 | Campos: nombres, apellidos, cédula, correo, teléfono, fecha de nacimiento, contraseña, política (si no se acepta, no se registra), código de referido opcional. **La BD genera:** `username` = inicial del nombre + primer apellido + 3–4 dígitos aleatorios (único, regenerando), `codigo_referido` UUID, `numero_cuenta` de 10 dígitos único, `rol=CLIENTE`, `estado=ACTIVO`. Hash bcrypt hecho en el backend. **5 `INGRESO_SIMULADO`** entre $10.000 y $1.000.000, con **fecha y hora aleatorias en el pasado**. Con `referido_por`: al verificar el correo, **$50.000** al referidor como `BONO_REFERIDO` («Bono por referir a <nombre>»); con la verificación apagada (flag) se paga al completar el registro |
| Spec §7.2 / §9 | Login solo por `username`; `BLOQUEADO` → mensaje exacto; el backend revalida rol y estado **en cada petición** |
| Contrato 18-nov §3.1 | `registrar_usuario(...)` → `{ username }`; `obtener_credenciales(p_username)` → `usuario_id, password_hash, rol, estado` (**0 filas** si no existe; el backend compara bcrypt y responde «Credenciales inválidas» idéntico); `validar_sesion(p_usuario_id)` lanza el mensaje de bloqueo; `GET /yo → { username, rol }` con `rol` obligatorio; `vista_perfil → { username, numero_cuenta (10 dígitos), codigo_referido (uuid) }`; el bono lo paga **una sola** función idempotente; el backend pasa `p_verificacion_activa` |
| Contrato §6 | `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla` · `Debe aceptar la política de datos` · `Credenciales inválidas` (lo emite el backend) · `Acceso denegado` (no-admin) · `Recurso no encontrado` |
| Contrato §1 | Funciones de cliente reciben `p_usuario_id` y corren `avanzar_hasta` primero (ver la desviación consciente de `vista_perfil`, sección 9); fechas del reloj del banco; errores de negocio `P0001`, cualquier otro es 503 |
| Plan Task 3 (FIX 5, 6, 7) | Firmas base; bono en **una** función; el backend compara bcrypt y luego llama `validar_sesion`; verificación y reenvío |
| Diseño consolidado | D3 (salidas `jsonb`), D5 (admin y usernames fijos solo-seed), D12a (todo error previsible → `P0001`), E.4-1 (un error no-`P0001` pinta el banner de caída), E.4-4 (enumeración: el backend usa bcrypt «señuelo»), E.4-7 (la política de contraseña vive en el backend) |
| E1/E2/E3 | `usuario` (CHECKs de formato, UNIQUE de cédula/correo/teléfono/username/código, `bono_referido_pagado`), `cuenta` (FK compuesta, 10 dígitos), `parametro` (bono 50 000; 5 ingresos; 10 000–1 000 000), plantillas `INGRESO_SIMULADO`/`BONO_REFERIDO` (CUENTA+RESULTADO, ambos `E`), `_asentar_grupo` (exige `READ COMMITTED`), regla de fecha del libro, `_reloj_instantanea()` |

**Reglas del front que condicionan el diseño** (`Registro.tsx`, `Login.tsx`, `client.ts`): envía `nombres, apellidos, cedula, correo, telefono, fecha_nacimiento (input date), password, acepta_politica, codigo_referido` (el `?ref=` crudo de la URL, **sin validar que sea UUID**); `400` → el mensaje se pinta tal cual; `503` → banner de caída; cualquier otro código → `Error NNN`. El mock actual usa mensajes que **no** son los del contrato (`Falta el campo X`, `Ya existe un usuario con esa cédula`) y un username sin la regla de dígitos: el contrato manda.

---

## 3. Validación técnica previa (laboratorios `e4_lab` y consultas de solo lectura, ya eliminados)

| # | Suposición | Resultado | Consecuencia |
|---|---|---|---|
| L1 | `unaccent()` está disponible para el dueño con `search_path = public` y normaliza `Ñandú Rodríguez-Peña Müller çñ` → `Nandu Rodriguez-Pena Muller cn`; también `Žofia Łukasz Øster ß Ærø` → `Zofia Lukasz Oster ss AEro`. **No translitera** otros alfabetos (`李明` queda igual) | ✅ | La *generación del username* debe tener una regla de respaldo para nombres sin letras latinas (5.3); eso **no** afecta a cómo se almacena el nombre |
| L2 | Un hash bcrypt real (`$2b$10$…`, 60 caracteres) cumple `^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$` y un texto plano no | ✅ | La BD **rechaza** cualquier `p_password_hash` que no tenga forma de bcrypt |
| L3 | Un `INSERT` en `usuario` que viola `uq_usuario_cedula/telefono/…` dentro de `BEGIN … EXCEPTION WHEN unique_violation` entrega `CONSTRAINT_NAME`, con el que se mapea a un mensaje `P0001` limpio | ✅ | Ningún `23505` llega al backend (sería 503) |
| L4 | **Carrera real:** dos sesiones registran la **misma cédula** a la vez; la 2.ª **espera** a la 1.ª, y tras su `COMMIT` falla con el mensaje mapeado | ✅ | Sin deadlock; la espera cabe en el `lock_timeout` de 3 s de `banco_app` |
| L5 | Un registro completo (usuario + cuenta + **5 grupos** por `_asentar_grupo`, con `nota` y `contraparte_nombre = 'Banco Digital'`) cuesta **≈ 33 ms** (75 ms en frío) | ✅ | Cabe en `statement_timeout = 5 s`; el libro acepta `nota`/`contraparte_nombre` en ingresos y bono y `contraparte_cuenta` en el bono |
| L6 | Las 5 patas de ingreso suman exactamente en `cuenta.balance` y `v_integridad_global.ok` sigue en `true` | ✅ | El balance inicial lo fija el libro |
| L7 | **Letras de cualquier alfabeto:** en la BD (`en_US.utf8`, UTF8) la clase `[[:alpha:]]` acepta `ж`, `李明`, `José`, `محمد` y **rechaza** `a1`, `a_b` y los dígitos arábigo-índicos (`٣`); `[0-9]` solo reconoce ASCII | ✅ | La validación de nombres para almacenar se hace con `[[:alpha:]]`. **Depende de la configuración regional de la BD** (creada en E0): una prueba lo verifica y falla con un mensaje claro si la BD se creara con otra |

De E2/E3: los triggers diferidos corren con el usuario de la sesión; la comprobación de FK toma `FOR KEY SHARE`; las funciones que llama una vista usan los privilegios de quien consulta; **E2 aseguraba que «ninguna función es ejecutable por `banco_app`»: E4 lo cambia por primera vez** (sección 10).

---

## 4. Catálogo de funciones

Convenciones (las de E2/E3): dueño `banco_owner`, `SECURITY DEFINER`, `SET search_path = public, pg_temp`, `COMMENT ON`, `REVOKE ALL … FROM PUBLIC`, errores de negocio `P0001`, mensajes que **no repiten la entrada del usuario**.

### 4.1 Públicas (`EXECUTE` solo `banco_app`; `banco_dev` por herencia; `banco_lector` no)

| Función | Parámetros | Retorno | Reloj |
|---|---|---|---|
| `registrar_usuario` | `p_nombres text, p_apellidos text, p_cedula text, p_correo text, p_telefono text, p_fecha_nacimiento text, p_password_hash text, p_acepta_politica boolean, p_codigo_referido text, p_verificacion_activa boolean` | `jsonb` `{ usuario_id, username }` | **1 instantánea** |
| `obtener_credenciales` | `p_username text` | `TABLE(usuario_id uuid, password_hash text, rol text, estado text)`; **0 filas** si no existe; **nunca lanza** por usuario inexistente | no |
| `validar_sesion` | `p_usuario_id uuid` | `jsonb` `{ username, rol, estado }`; lanza el mensaje de bloqueo | no |
| `verificar_correo` | `p_usuario_id uuid` | `void`; idempotente | **1 instantánea** |
| `vista_perfil` | `p_usuario_id uuid` | `jsonb` `{ username, numero_cuenta, codigo_referido }` | no |
| *(**condicional**, D-E4-9)* `datos_reenvio_verificacion` | `p_username text` | `TABLE(usuario_id uuid, correo text)`: 0 filas si no existe **o** ya está verificado; nunca lanza | no |

* **`datos_reenvio_verificacion` NO se implementa, NO recibe `EXECUTE` y NO se cuenta en la lista blanca de `banco_app` hasta que Juan confirme que su backend publicará `POST /auth/reenviar`.** Si Juan lo confirma: se añade en una sub-etapa (E4.4b) con sus pruebas y la lista blanca pasa de 5 a 6; si no, **no existe**. Se evita publicar una función que el backend no vaya a usar.
* **`p_fecha_nacimiento` y `p_codigo_referido` son `text`** (el plan decía `date`/`uuid`) para que ninguna entrada del usuario cause un error de *driver* (`22P02`/`22007` → 503); ver desviaciones en la sección 9.
* `obtener_credenciales` conserva `RETURNS TABLE` (0 filas) por el contrato; es la **única** función que devuelve `password_hash`.

### 4.2 Internas (sin `EXECUTE` para nadie salvo el dueño)

| Función | Tipo | Rol |
|---|---|---|
| `_validar_cliente(p_usuario_id uuid)` → registro `usuario` | plpgsql | Usuario existe (si no: `Sesión inválida`), es `CLIENTE` (si no: `Acceso denegado`), no está `BLOQUEADO` (si lo está: el mensaje exacto). **Helper para E5–E10** |
| `_validar_admin(p_admin_id uuid)` → registro `usuario` | plpgsql | Existe, `ADMIN` y activo; si no: `Acceso denegado` (bloqueado: mensaje de bloqueo). **Helper para E11–E12** |
| `_pagar_bono_referido(p_usuario_id uuid, p_ahora timestamptz)` → `boolean` | plpgsql | **Única** implementación del bono. Recibe el `ahora` de la operación que la llama (**no** consulta el reloj) |
| `_reglas_registro()` → `jsonb` | pura, `IMMUTABLE` | **Todos los valores provisionales** (edad, longitudes, formatos…) en un solo lugar (5.7) |
| `_msg_auth(p_clave text)` → `text` | pura, `IMMUTABLE` | **Todos los mensajes** de E4 (contractuales y provisionales) en un solo lugar (sección 11) |
| `_norm_texto(text)` → `text` | pura | trim + colapsa espacios internos; **conserva** mayúsculas, tildes y alfabetos tal cual (para guardar el nombre real) |
| `_norm_digitos(p_texto text, p_permite_mas_inicial boolean)` → `text` | pura | Deja solo dígitos ASCII. `NULL` si hay un carácter no permitido o un `+` fuera de la primera posición (o un `+` cuando `p_permite_mas_inicial` es `false`) (5.2) |
| `_norm_cedula(text)` → `text` | pura | Reglas de cédula (5.2): sin `+`, separadores solo `.` y espacio |
| `_norm_telefono(text)` → `text` | pura | Reglas de teléfono (5.2): `+` solo al inicio; canónico en dígitos |
| `_username_base(nombres text, apellidos text)` → `text` | pura | `inicial + primer apellido` en minúsculas sin tildes, con respaldo para alfabetos sin equivalente latino (5.3) |
| `_edad_en(nacimiento date, hoy date)` → `integer` | pura | años cumplidos a `hoy` (con la fecha del banco, **no** `current_date`) |
| `_es_hash_bcrypt(text)` → `boolean` | pura | forma `$2a/$2b/$2y$NN$` + 53 caracteres del alfabeto bcrypt |

Las puras reciben todo por parámetro: **ninguna interna consulta el reloj, `now()` ni `current_date`**. Total de funciones del esquema: 29 → **46** (47 si se confirma la condicional).

---

## 5. Cómo funciona

### 5.1 `registrar_usuario` (un solo `SELECT`, una sola transacción, `READ COMMITTED`)

```
 1  política        NOT p_acepta_politica                         → 'Debe aceptar la política de datos'          (contrato §6)
 2  presencia       campos vacíos / NULL                          → 'Datos de registro incompletos'
 3  formato (sin reloj)  nombres, apellidos, cédula, correo, teléfono, hash bcrypt, fecha en texto, uuid en texto
 4  instantánea     SELECT hoy, ahora FROM _reloj_instantanea()    ← UNA vez; FOR SHARE hasta el COMMIT
 5  edad            fecha ≤ hoy, edad ≥ mínima y ≤ máxima (con 'hoy' del banco)
 6  referido        código en texto → uuid → fila de CLIENTE      → si no existe: 'Código de referido inválido'   (provisional)
 7  duplicados      cédula, correo, teléfono (en ese orden); la carrera la cubre el UNIQUE (sección 6)
 8  usuario         username = base + 3 dígitos (30 intentos) y luego 4 dígitos (30); INSERT con creado_en = ahora
 9  cuenta          numero_cuenta aleatorio de 10 dígitos (prefijo '40'), único; INSERT con creado_en = ahora
10  5 ingresos      fechas por estratos (5.4); monto entero en [min,max] de `parametro`; cada uno = UN grupo por
                    _asentar_grupo(fecha_i, [CUENTA E, RESULTADO E]) tipo INGRESO_SIMULADO,
                    nota 'Ingreso simulado', contraparte_nombre 'Banco Digital'
11  bono            si hay referidor y NOT p_verificacion_activa → _pagar_bono_referido(nuevo, ahora)
12  salida          { usuario_id, username }
```

* **Todo o nada:** cualquier fallo en **cualquier** paso (incluso después de escribir patas del libro) revierte usuario, cuenta, ingresos y bono (sección 6).
* El orden hace que «Registro sin aceptar política» dé **siempre** el mensaje exacto del contrato.
* Las validaciones sin reloj (1–3) ocurren **antes** de tomar la instantánea: una petición inválida no toma el bloqueo del reloj.
* `p_verificacion_activa` `NULL` se trata como `true` (no se paga dinero por una entrada ambigua).
* Los ingresos se insertan en orden ascendente de fecha para que `orden` (inserción) y `fecha` coincidan.

### 5.2 Normalización y validación

**Hay dos validaciones distintas y no se confunden:**

* **(A) Validación para ALMACENAR el nombre:** el nombre real se guarda con sus caracteres internacionales. Es lo único que se exige para aceptar `nombres`/`apellidos`.
* **(B) Regla para GENERAR el username** (5.3): tiene sus propias restricciones (solo `[a-z0-9]`) y **nunca rechaza un registro**: si el nombre no produce letras latinas usa un respaldo. Un nombre en cirílico, chino o árabe **se registra y se almacena intacto**; solo su username usa el respaldo.

| Campo | Normalización | Validación (para almacenar) | Mensaje |
|---|---|---|---|
| nombres / apellidos | `_norm_texto`: trim, espacios colapsados; **se conservan** mayúsculas, tildes y alfabetos | 2–60 caracteres; cada carácter es una **letra de cualquier alfabeto** (`[[:alpha:]]`), espacio, apóstrofo (`'` o `’`), punto o guion; sin dígitos, controles ni símbolos; al menos una letra. **No** se exige ninguna letra a–z | `Nombre inválido` / `Apellido inválido` |
| cédula | `_norm_cedula` (abajo) | solo dígitos, **6–10** *(provisional D-E4-13)* | `Cédula inválida` |
| correo | trim + minúsculas | patrón de `ck_usuario_correo_formato`, ≤ 254 | `Correo inválido` |
| teléfono | `_norm_telefono` (abajo) | ver reglas (abajo) *(provisional D-E4-13)* | `Teléfono inválido` |
| fecha nacimiento | trim | `YYYY-MM-DD` real (rechaza 30-feb); entre 1900-01-01 y `hoy`; edad **≥ 18** y ≤ 120 *(provisional)* | `Fecha de nacimiento inválida` / `Debes ser mayor de edad para registrarte` |
| password_hash | — | `_es_hash_bcrypt`, ≤ 100 | `Datos de registro inválidos` |
| código de referido | trim; vacío = sin referido | UUID válido **y** de un `CLIENTE` existente *(error vs. ignorar: D-E4-14)* | `Código de referido inválido` |

**Reglas específicas de cédula y teléfono** (`_norm_digitos` es la pieza común; el resultado se guarda **solo en dígitos**, como exige `ck_usuario_cedula_digitos`/`ck_usuario_telefono_digitos` de E1):

| | Cédula | Teléfono |
|---|---|---|
| Separadores admitidos (se eliminan) | espacio y `.` (miles: `1.234.567`) | espacio, `-`, `(` y `)` |
| Signo `+` | **nunca** (cualquier `+` → inválida) | **solo como primer carácter** (tras recortar espacios) y **una sola vez**; un `+` en cualquier otra posición → inválido |
| Cualquier otro carácter (letras, `/`, `_`, etc.; dígitos no ASCII) | inválida | inválido |
| Sin `+` | 6–10 dígitos | exactamente **10** dígitos (nacional) |
| Con `+` (internacional) | — | 8–15 dígitos (E.164: código de país + número) |
| Forma canónica guardada | los dígitos | nacional: los 10 dígitos; internacional: los dígitos con código de país; **`+57` seguido de 10 dígitos se guarda como esos 10 dígitos** (la misma línea colombiana no puede registrarse dos veces con formas distintas y burlar el `UNIQUE`) |
| Ejemplos válidos | `1.234.567`, `80 123 456` | `3001234567`, `300 123 4567`, `(300) 123-4567`, `+57 300 123 4567` → `3001234567`, `+1 415 555 2671` → `14155552671` |
| Ejemplos inválidos | `+1234567`, `12+34567`, `123-4567`, `12a4567` | `3001+234567`, `+57+3001234567`, `573001234567` (12 dígitos **sin** `+`: ambiguo), `300123`, `++573001234567` |

Los mensajes **nunca incluyen** lo que escribió el usuario.

### 5.3 Username y número de cuenta

* **`_username_base` (regla B; independiente de la validación A):** se normaliza con `unaccent` + minúsculas y se conservan solo `[a-z0-9]`. **Inicial** = primera letra a–z del primer nombre; **apellido** = primer token de `apellidos` que **no** sea partícula (`de, del, la, las, los, y, e, da, di, do, van, von`), truncado a 20 caracteres. **Respaldo** (sin rechazar nunca el registro): si no hay inicial a–z se usa `u`; si no hay apellido a–z se usa `usuario`. Ej.: *Juan Pérez* → `jperez`; *María del Pilar Núñez* → `mnunez`; *Ivan Петров* → `iusuario`; *李明 王* → `uusuario`. El username es un identificador, no una representación del nombre.
* **Dígitos:** hasta 30 intentos con 3 dígitos (100–999) y luego hasta 30 con 4 (1000–9999); cada intento es un `INSERT` en subtransacción que captura `uq_usuario_username` (cubre también la carrera). Si se agotan (≈ 9 900 usuarios con la misma base): `No fue posible generar el usuario, intenta de nuevo`. Debe cumplir `ck_usuario_username` (`^[a-z][a-z0-9]{2,29}$`).
* **`numero_cuenta`:** `'40'` + 8 dígitos aleatorios (coherente con `4001002003` del seed; 10⁸ posibles); reintento por unicidad.
* El **seed** (E14, D5) necesitará usernames/cuentas fijos (`jperez483`, `cgomez12`, `admin1`, `bloqueado1`, `4001002003`): **no** se implementa aquí; E14 los crea con funciones solo-seed que reutilizan las validaciones puras.

### 5.4 Ingresos simulados — fechas distintas, ascendentes y dentro de 90 días **por construcción**

No se confía en que el azar produzca fechas distintas. Con `n = parametro.ingresos_simulados_cantidad` (5):

1. Ventana `V = [ahora − 90 días, ahora − 1 minuto]` (todas **estrictamente anteriores** a la instantánea y a lo sumo 90 días antes).
2. `V` se divide en `n` **estratos consecutivos y disjuntos** de igual ancho (≈ 18 días para n = 5; el ancho mínimo posible, con `n` hasta 32 767, es de ≈ 237 s: siempre ≥ 1 s).
3. La fecha *i* = inicio del estrato *i* + `random() × ancho` truncada al segundo, **dentro de su estrato**. Como los estratos son disjuntos y están ordenados, las fechas son **distintas y estrictamente ascendentes siempre**, sea cual sea el resultado del azar.
4. **Autoverificación defensiva** antes de escribir en el libro: se comprueba que la secuencia es estrictamente ascendente, distinta y está en `V`; si no (error de programación), `RAISE` y se revierte todo. Una mutación la desactiva y las pruebas lo detectan.
5. Los grupos se asientan **en orden ascendente** (un grupo por ingreso, cada uno con su fecha). Monto entero en pesos en `[ingreso_simulado_min, ingreso_simulado_max]` de `parametro`; `nota 'Ingreso simulado'`, `contraparte_nombre 'Banco Digital'`. La cuenta nace con `balance = Σ`, fijado por el libro.

### 5.5 Referidos y bono (`_pagar_bono_referido`)

1. `SELECT … FROM usuario WHERE id = nuevo FOR UPDATE` (serializa verificaciones simultáneas del mismo usuario).
2. Sale con `false` (no hace nada) si: no existe, `referido_por IS NULL` (sin referidor o referidor borrado → `SET NULL`), o `bono_referido_pagado` ya es `true`.
3. Un grupo `BONO_REFERIDO` por `_asentar_grupo(p_ahora, …)`: `CUENTA E` del **referidor** + `RESULTADO E`, monto `parametro.bono_referido`, `nota = 'Bono por referir a <primer nombre> <primer apellido>'`, `contraparte_nombre = 'Banco Digital'`, `contraparte_cuenta` = número de cuenta del referido (vínculo auditable, ver 10).
4. `UPDATE usuario SET bono_referido_pagado = true` **en la misma transacción**: o ocurren las dos cosas o ninguna → exactamente un bono por referido, aunque se llame mil veces o en paralelo.

Se llama desde exactamente **dos** lugares: `registrar_usuario` (verificación apagada) y `verificar_correo`. **Sin trigger** (D-E4-6, aprobada).

### 5.6 `verificar_correo`, `validar_sesion`, `obtener_credenciales`, `vista_perfil`

* **`verificar_correo`**: instantánea **una vez**; lee el usuario `FOR UPDATE`; si no existe → `Recurso no encontrado`; si ya está verificado → no-op idempotente; si no, `correoverificado := true` y `_pagar_bono_referido(id, ahora)`. No exige cuenta activa (el enlace del correo no trae sesión).
* **`validar_sesion`**: `PK` lookup sin bloqueo; `Sesión inválida` si no existe; el mensaje exacto de bloqueo si `BLOQUEADO`; `{ username, rol, estado }`. Lee el estado **vivo** en cada llamada.
* **`obtener_credenciales`**: `lower(btrim(p_username))`; 0 filas si no existe; devuelve también al `BLOQUEADO` (el backend compara bcrypt **antes** de `validar_sesion`, así el mensaje de bloqueo solo se ve con la clave correcta).
* **`vista_perfil`**: `_validar_cliente` + `{ username, numero_cuenta, codigo_referido }`. **No** ejecuta `avanzar_hasta`: **desviación consciente del contrato** (sección 9).

### 5.7 Reglas provisionales centralizadas (un único lugar)

Los valores que dependen de decisiones del equipo **no** están dispersos por las funciones: viven en **`_reglas_registro()`** (valores) y **`_msg_auth()`** (mensajes), ambas puras (`IMMUTABLE`) en `13_auth_utilidades.sql`, y las pruebas fijan su contenido exacto (cambiar una regla obliga a cambiar la prueba, deliberadamente).

| Clave en `_reglas_registro()` | Valor provisional | Decisión del equipo |
|---|---|---|
| `edad_minima` / `edad_maxima` | 18 / 120 | D-E4-12 |
| `cedula_min` / `cedula_max` | 6 / 10 | D-E4-13 |
| `telefono_nacional_digitos` | 10 | D-E4-13 |
| `telefono_internacional_min` / `_max` | 8 / 15 | D-E4-13 |
| `nombre_min` / `nombre_max` | 2 / 60 | — (técnico) |
| `username_dias`, `ingresos_ventana_dias` | 3 dígitos×30 y 4 dígitos×30 / 90 | — (técnico, D-E4-3/5 aprobadas) |

Las **cuatro decisiones de comportamiento** del equipo no son un parámetro numérico: cada una se implementa **en un único punto del código**, comentado y con su prueba, para que cambiarla sea una edición localizada:

| Decisión | Comportamiento provisional | Dónde cambiarlo |
|---|---|---|
| D-E4-14 Código de referido inexistente | **Error** `Código de referido inválido` | paso 6 de `registrar_usuario` |
| D-E4-17 Mensaje de duplicados (**negocio pendiente**) | **Específico** (cédula/correo/teléfono) | claves `dup_*` de `_msg_auth()` (pasar a uno genérico = cambiar 3 literales) |
| D-E4-18 `correoverificado` con verificación apagada | **`false`** | rama `NOT p_verificacion_activa` de `registrar_usuario` |
| D-E4-19 Bono a referidor bloqueado (**negocio pendiente**) | **Paga siempre** | `_pagar_bono_referido`, un solo `IF` |

---

## 6. Concurrencia y atomicidad

| Escenario | Garantía |
|---|---|
| Dos registros con la **misma cédula/correo/teléfono** a la vez | El `UNIQUE` serializa; el 2.º espera y recibe el mensaje propio (L3/L4). Nunca `23505` ni 503 |
| Muchos registros con el **mismo nombre** (misma base de username) | Reintentos por subtransacción; usernames distintos; sin deadlock |
| Misma verificación enviada N veces / en paralelo | `FOR UPDATE` del usuario + bandera `bono_referido_pagado` en la misma transacción: **un** bono |
| Muchos referidos de un mismo referidor registrándose a la vez | Cada bono bloquea la cuenta del referidor con `_asentar_grupo` (orden de id): se serializan sin ciclos; el balance final es exacto |
| Registro ∥ cambio del reloj por el admin | La instantánea toma `FOR SHARE`: el admin espera a que termine el registro (≈ 35 ms) y el registro ve una sola fecha |
| Aislamiento | `READ COMMITTED` (el de `pg` por defecto); `_asentar_grupo` lo exige y devuelve `P0001` si no |

**Atomicidad — garantía y cómo se demuestra.** Una llamada = una sentencia = una transacción: **cualquier** fallo (restricción, libro, bloqueo, corte de conexión) revierte **todo**: `usuario`, `cuenta`, los 5 ingresos, el bono y la bandera `bono_referido_pagado`. Las pruebas no se limitan a fallos tempranos: inyectan el fallo **en cada punto del recorrido, incluidos puntos posteriores a haber escrito patas del libro**:

| Punto de fallo inyectado (solo en `banco_test`, con un *trigger* de prueba) | Qué ya se había escrito |
|---|---|
| F1 al insertar la `cuenta` | `usuario` |
| F2…F6 al escribir la 1.ª pata del grupo de ingreso *k* (k = 1…5) y también **entre la 1.ª y la 2.ª pata** del grupo | usuario, cuenta y *k − 1* ingresos completos (y la 1.ª pata del grupo *k* en el segundo caso) |
| F7 tras los 5 ingresos, antes del bono | usuario, cuenta y 5 ingresos (patas ya escritas y con saldos aplicados) |
| F8 en la 1.ª pata del grupo del bono | todo lo anterior |
| F9 en la 2.ª pata del bono (la del referidor ya escrita, con su saldo aplicado) | todo lo anterior + la pata del referidor |
| F10 al marcar `bono_referido_pagado = true` | todo lo anterior, bono incluido |
| F11 en `verificar_correo` tras el bono (antes de `correoverificado`) | patas del bono |
| F12 corte de conexión (`pg_terminate_backend`) en medio de cualquiera de los puntos anteriores | lo escrito hasta ese punto |

Tras cada caso se comprueba, **en la misma sesión (con `SAVEPOINT`) y desde una conexión distinta sobre el estado confirmado**: cero filas nuevas en `usuario`, `cuenta` y `transaccion`; el saldo y la bandera del referidor intactos; el `tests.huella_saldos()` idéntico; `v_integridad_global.ok`; y que un reintento posterior (sin fallo) funciona. (Las secuencias `orden` pueden quedar con huecos: es esperado y no afecta a nada.)

Orden de bloqueo (sin ciclos): fila de `reloj` (compartida) → filas **nuevas** propias → cuenta del referidor (vía `_asentar_grupo`).

---

## 7. Uso del reloj (tu regla, hecha cumplir)

| Función | Llama `_reloj_instantanea()` | Usa |
|---|---|---|
| `registrar_usuario` | **1 vez**, tras las validaciones sin reloj | `hoy` → edad; `ahora` → `creado_en` de usuario y cuenta, base de la ventana de los 5 ingresos, fecha del bono |
| `verificar_correo` | **1 vez** | `ahora` → fecha del bono |
| el resto (públicas e internas) | **0** | — (reciben `ahora`/`hoy` por parámetro) |

**Enforcement por catálogo (prueba obligatoria):** el texto de las funciones de E4 se escanea: exactamente una llamada a `_reloj_instantanea()` en cada una de las dos funciones; **cero** apariciones de `now()`, `current_date`, `current_timestamp`, `clock_timestamp()`, `hoy_banco()`, `ahora_banco()` o `_ahora_real()` en cualquiera. Además: tiempo inyectado (mayoría de edad en el día exacto y en la frontera de medianoche; operación que espera el reloj y cruza la medianoche), reloj manual adelantado y durante el seed.

---

## 8. Seguridad

* **Superficie de `banco_app`:** 5 funciones (6 si se confirma la condicional) y nada más. No lee tablas ni `usuario.password_hash`; el hash solo sale por `obtener_credenciales` y nunca entra en un mensaje de error ni en `jsonb` (lo prueba un escaneo de la salida de todas las funciones).
* **La BD nunca ve la clave en claro:** rechaza lo que no tenga forma de bcrypt. `log_statement = none` evita que el hash llegue a logs.
* **Sin SQL dinámico**; parámetros siempre tipados; los mensajes no incluyen entrada del usuario.
* **El rol nunca es entrada:** `registrar_usuario` solo crea `CLIENTE`/`ACTIVO`; no existe camino público para crear `ADMIN` (E14 lo hace solo-seed).
* **Enumeración (E.4-4):** `obtener_credenciales` devuelve 0 filas sin error; el backend debe usar el bcrypt «señuelo» y responder idéntico. Los mensajes de duplicado **sí revelan existencia** (**decisión de negocio pendiente D-E4-17**; provisional: específicos; alternativa: un genérico). Se mitiga con el rate limit del backend.
* **Abuso:** el registro «acuña» saldo simulado por diseño del spec y el bono permite granjas de cuentas referidas (**D-E4-19**, negocio pendiente); el rate limit/captcha son del backend.
* **Límites que siguen:** superusuario (ya documentado), reloj del servidor (E3).

---

## 9. Contraste con el contrato del front

| Endpoint | Función | Entrada del front → parámetro | Salida | Errores (todos `P0001`) | Estado |
|---|---|---|---|---|---|
| `POST /auth/registro` | `registrar_usuario` | `nombres, apellidos, cedula, correo, telefono, fecha_nacimiento` (texto `YYYY-MM-DD`), `acepta_politica`, `codigo_referido` (texto o ausente → `NULL`), `password` → bcrypt del backend → `p_password_hash`; el backend añade `p_verificacion_activa` | `{ usuario_id, username }` (el backend responde `{ username }`) | `Debe aceptar la política de datos` (contrato) + los provisionales (sección 11) | ✅ **con 2 `text`** |
| `POST /auth/login` | `obtener_credenciales` → bcrypt (backend) → `validar_sesion` | `{ username, password }` | 0 filas → `Credenciales inválidas` (backend); `estado` → mensaje de bloqueo | `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla` | ✅ |
| `GET /yo` | `validar_sesion` | `p_usuario_id` (de la cookie) | `{ username, rol, estado }` → el front lee `username` y `rol` (**obligatorio**) | bloqueo con sesión abierta; `Sesión inválida` si el usuario fue borrado | ✅ |
| `GET /perfil` | `vista_perfil` | `p_usuario_id` | `{ username, numero_cuenta (10 dígitos, string), codigo_referido (uuid) }` | bloqueo | ✅ **con la desviación D-1** |
| verificar correo (sin UI) | `verificar_correo` | `p_usuario_id` (del token del enlace) | `void` | `Recurso no encontrado` | ✅ |
| reenviar verificación (sin UI) | *(condicional)* `datos_reenvio_verificacion` | `p_username` | 0 filas o `(usuario_id, correo)` | — | ⏳ **solo si Juan confirma** |

### Desviaciones conscientes respecto del contrato

| # | Desviación | Justificación |
|---|---|---|
| **D-1** | **`vista_perfil` NO ejecuta `avanzar_hasta`** (el contrato §1 lo pide para toda lectura de cliente) | El perfil (`username`, `numero_cuenta`, `codigo_referido`) **no contiene información financiera ni dependiente del tiempo**; además `avanzar_hasta` no existe hasta E7. Sigue validando sesión, rol y bloqueo (`_validar_cliente`). **Aprobada por el responsable de BD** como desviación consciente; se revisará en E7 solo si el equipo lo pide |
| D-2 | `p_fecha_nacimiento` y `p_codigo_referido` son `text` (plan: `date`/`uuid`) | El front manda el `?ref=` sin validar; un `uuid`/`date` inválido causaría un error de driver → **503** ante un error del usuario. La BD valida y responde `P0001`. Se avisa a Juan |
| D-3 | `validar_sesion` devuelve `jsonb` `{ username, rol, estado }` (plan: `TABLE(rol, estado)`) | D3 (salidas `jsonb`); `GET /yo` necesita `username` y `rol` |
| D-4 | `registrar_usuario` devuelve también `usuario_id` | El backend lo necesita para firmar el token de verificación; **solo `{ username }` llega al front** |
| D-5 | `Sesión inválida` para un usuario inexistente (el contrato no define el mensaje) | Provisional (D-E4-16); sin ella el usuario borrado con sesión abierta recibiría datos o un error no-`P0001` |

Observaciones que **se comunican, no se resuelven aquí** (detalle en el resumen para Juan):
1. **Mensajes del mock ≠ contrato** (`Falta el campo X`, `Ya existe un usuario con esa cédula`): manda el contrato/BD.
2. **Mock sin la regla de dígitos del username**: la BD genera `inicial+apellido+3–4 dígitos`.
3. **`Yo.rol?` es opcional en `types.ts`** pero el contrato lo exige: la BD siempre lo entrega.
4. El **backend debe** comparar bcrypt **antes** de `validar_sesion`, usar bcrypt señuelo con 0 filas y responder `{ username }` en el registro.
5. La política de contraseña (8, mayúscula, número) vive en el **backend** (E.4-7).

---

## 10. Integración con etapas anteriores (cambios mínimos y justificados)

| Archivo | Cambio | Porqué |
|---|---|---|
| `13_auth_utilidades.sql` (nuevo) | utilidades puras (`_reglas_registro`, `_msg_auth`, normalizadores, `_username_base`, `_edad_en`, `_es_hash_bcrypt`) | — |
| `14_auth_funciones.sql` (nuevo) | funciones públicas (5), `_validar_*`, `_pagar_bono_referido`, permisos | — |
| `14b` (**condicional**) | `datos_reenvio_verificacion` | solo si Juan confirma |
| `09_integridad.sql` | **(a)** el control «ninguna función ejecutable por `banco_app`» pasa a «`banco_app` ejecuta **exactamente** las 5 públicas (6 si se confirma la condicional) y ninguna otra»; **(b)** +2 controles: `usuarios_sin_cuenta` (todo `CLIENTE` tiene cuenta; `ADMIN` ninguna) y `bonos_inconsistentes` (`bono_referido_pagado = true` ⇔ exactamente **un** grupo `BONO_REFERIDO` cuya `contraparte_cuenta` es la cuenta del referido y cuya cuenta propietaria es la del referidor) | Primer `EXECUTE` de `banco_app`; E4 introduce invariantes nuevas que deben ser **detectables** por la verificación independiente |
| Pruebas `03`, `08`, `10`, `16`, `09`, `helpers.sql`, `harness.sql` | inventario de funciones (29 → 46), permisos de `banco_app`, lista `SECURITY DEFINER`, conteo de controles; el *trigger* de inyección de fallos y los constructores de datos viven **solo en `harness.sql`** (`banco_test`) | Adaptar, conservando su significado (como en E3). **No se hace en esta etapa de diseño** |
| `03_schema.sql`, `ctl.ps1` | **sin cambios** | — |

No se modifica ninguna función de E2/E3.

---

## 11. Mensajes de error (todos en `_msg_auth()`)

Del **contrato** (exactos): `Debe aceptar la política de datos`, `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla`, `Acceso denegado`, `Recurso no encontrado`.

**Nuevos — PROVISIONALES hasta que el equipo resuelva D13** (no se presentan como aprobados; cambiarlos es editar un literal en `_msg_auth()` y su prueba): `Datos de registro incompletos` · `Datos de registro inválidos` · `Nombre inválido` · `Apellido inválido` · `Cédula inválida` · `Correo inválido` · `Teléfono inválido` · `Fecha de nacimiento inválida` · `Debes ser mayor de edad para registrarte` · `La cédula ya está registrada` · `El correo ya está registrado` · `El teléfono ya está registrado` · `Código de referido inválido` · `Sesión inválida` · `No fue posible generar el usuario, intenta de nuevo`.

---

## 12. Estrategia de pruebas

| Archivo (nuevo) | Qué prueba | Aserc. aprox. |
|---|---|---|
| `40_auth_normalizacion` | Utilidades puras: `_norm_texto`; **nombres en cualquier alfabeto** (cirílico, chino, árabe, latino con tildes, apóstrofos, guiones) se aceptan y se guardan **intactos**, y se rechazan dígitos/controles/símbolos; la prueba de la **configuración regional** de la BD (L7); `_norm_digitos`/`_norm_cedula`/`_norm_telefono` con **todas** las reglas de 5.2 (`+` solo al inicio del teléfono, nunca en cédula, `+57` canónico, 12 dígitos sin `+`, E.164, separadores); `_username_base` (tildes, ñ, partículas, compuestos, **respaldo** para alfabetos sin equivalente latino, longitud); `_edad_en` (fronteras, 29-feb); `_es_hash_bcrypt` (válidos y 30 formas inválidas); contenido exacto de `_reglas_registro()` y `_msg_auth()` | 75 |
| `41_auth_registro` | Registro feliz: forma exacta del `jsonb`, username (`^[a-z]+[0-9]{3,4}$`), cuenta única de 10 dígitos, `rol`/`estado`/`correoverificado`/`bono_referido_pagado`, `creado_en`; cada validación con su mensaje exacto y su orden (política primero); **nombre chino/cirílico: se registra, se almacena intacto y el username usa el respaldo**; 300 registros con el mismo nombre → usernames distintos y paso a 4 dígitos al forzar el agotamiento; duplicados; inyecciones SQL/Unicode/espacios; el hash no aparece en ninguna salida | 110 |
| `42_auth_ingresos` | Exactamente 5 grupos de 2 patas; montos enteros en el rango de `parametro`; **fechas estrictamente ascendentes, distintas, ≥ `ahora − 90 días` y < `ahora`, para miles de registros y con `random()` sesgado (semillas y simulación de «peor azar»: todos los valores en los extremos 0 y casi 1)**; la autoverificación defensiva dispara si se rompe el invariante; `nota`/contraparte; `cuenta.balance` = Σ; cuadre e integridad; con el reloj manual adelantado y atrasado (banco vacío) | 50 |
| `43_auth_referidos` | Referido válido/inválido/de ADMIN/borrado; verificación apagada (bono al registrar) y encendida (bono al verificar); `verificar_correo` ×N = un bono; sin referidor; referidor bloqueado (comportamiento provisional D-E4-19); nota, monto de `parametro`, `contraparte_cuenta`; los 2 controles de integridad detectan sabotajes | 55 |
| `44_auth_sesion` | `obtener_credenciales` (0 filas, mayúsculas, espacios, hash solo aquí, BLOQUEADO y ADMIN se devuelven); `validar_sesion` (cliente, admin, bloqueado = mensaje exacto, borrado, bloqueo con «sesión abierta»); `vista_perfil` (**y que NO llama a `avanzar_hasta` ni toca datos financieros**); `_validar_cliente/_validar_admin` (matriz rol × estado) | 55 |
| `45_auth_permisos` | `EXECUTE` por rol (app sí en las 5 y solo en esas, lector/dev/PUBLIC no), dueño, `SECURITY DEFINER`, `search_path`; `banco_app` sin acceso a tablas; (si Juan confirma: la 6.ª con el mismo patrón) | 40 |
| `46_auth_reloj` | **Catálogo:** exactamente 1 `_reloj_instantanea()` en `registrar_usuario` y 1 en `verificar_correo`, 0 en el resto, ninguna aparición de `now()`/`current_date`/`hoy_banco()`/…; **tiempo inyectado:** mayoría de edad el día exacto del cumpleaños y a medianoche, registro cuya espera del reloj cruza la medianoche, reloj manual; `creado_en` y los ingresos usan la misma `ahora` | 35 |
| `47_auth_aleatorio` | Entradas aleatorias válidas e inválidas contra un **oráculo** independiente (aceptar/rechazar y mensaje), 2000 iteraciones; invariantes globales (integridad, unicidad, `Σ ingresos = balance`) | 20 |
| **`48_auth_atomicidad`** | **Fallos inyectados F1–F11 de la sección 6** (con *trigger* de prueba y `SAVEPOINT`): tras cada uno, cero filas nuevas, saldos y bandera intactos, huella idéntica, integridad ok y reintento exitoso; incluye **fallos posteriores a la escritura de patas del libro** (entre patas de un grupo, tras los 5 ingresos, durante el bono, al marcar la bandera, en `verificar_correo`) | 40 |
| Conexiones reales `reales/39_auth_conexiones` | `banco_app` por TCP: registro completo, login (credenciales + estado), bloqueo en sesión abierta, perfil, verificación; sin acceso a tablas ni al hash; lector/dev; **fallos inyectados y corte de conexión (F12) con verificación del estado confirmado desde otra conexión** | 50 |
| Concurrencia `reales/40_auth_concurrencia` | 8 sesiones registran la **misma cédula** (1 gana, 7 mensaje propio); 12 con el **mismo nombre** (usernames distintos); 10 `verificar_correo` simultáneos (1 bono); 15 registros referidos por el mismo usuario (saldo exacto); registros ∥ cambios del reloj (0 errores, 0 deadlocks) | 25 |
| **Mutación** | ≈ 32: quitar política/edad/validación del hash/regla de `+`; username sin reintento; ingresos con `INSERT` directo; **ingresos con fechas iguales o desordenadas (autoverificación desactivada)**; ingresos fuera de 90 días o futuros; bono sin bandera (doble pago); bono sin `FOR UPDATE`; `banco_app` con `EXECUTE` de una interna o `SELECT` de `usuario`; `obtener_credenciales` que lanza; `validar_sesion` sin mensaje de bloqueo; una llamada extra a `_reloj_instantanea()` o un `now()`; **registro sin subtransacción/atomicidad (commit parcial)**; controles de integridad desactivados… | 32 |
| **Adaptación de E1/E2/E3** | `03`, `08`, `10`, `16`, `09` (reaplica 00–14) | — |

Total estimado: **≈ 540 aserciones nuevas** (sobre las 1197) y 32 mutaciones. Evidencias estilo E3: suite completa, mutaciones, reset + 3 `apply`, demostración `04-pgadmin-demo.sql` con `ROLLBACK`, `git status`.

---

## 13. Decisiones

### Técnicas (del responsable de BD)

| ID | Decisión | Estado |
|---|---|---|
| D-E4-1 | Firmas con `text` para `p_fecha_nacimiento` y `p_codigo_referido`; salidas `jsonb` salvo `obtener_credenciales` (`TABLE`) | ✅ **Aprobada** |
| D-E4-2 | `registrar_usuario` solo crea `CLIENTE`; sin parámetros «forzar»; el seed tendrá funciones solo-seed (E14) | ✅ **Aprobada** |
| D-E4-3 | Algoritmo de username (3 dígitos ×30, 4 ×30). **Revisión:** la regla de generación es independiente de la validación del nombre y tiene respaldo (`u`/`usuario`) para alfabetos sin equivalente latino | ✅ **Aprobada** (con la aclaración 1 incorporada en 5.2/5.3) |
| D-E4-4 | `numero_cuenta` = `'40'` + 8 dígitos aleatorios | ✅ **Aprobada** |
| D-E4-5 | Ingresos: monto entero, ventana 90 días, 5 grupos. **Revisión:** fechas distintas, ascendentes y dentro de la ventana **por construcción** (estratos) con autoverificación | ✅ **Aprobada** (con la aclaración 5 incorporada en 5.4) |
| D-E4-6 | Bono por llamadas explícitas, sin trigger; referido borrado → sin bono; nota con primer nombre + primer apellido | ✅ **Aprobada** (el comportamiento con referidor bloqueado queda como D-E4-19, provisional) |
| D-E4-7 | La BD rechaza hashes que no tengan forma de bcrypt | ✅ **Aprobada** |
| D-E4-8 | `_validar_cliente`/`_validar_admin` en E4; `vista_perfil` y `validar_sesion` sin `avanzar_hasta` | ✅ **Aprobada** (`vista_perfil`: desviación consciente D-1, sección 9) |
| **D-E4-9** | **Función `datos_reenvio_verificacion(p_username)` y su `EXECUTE` (6.ª función pública)** | ⏳ **PENDIENTE de confirmación de Juan.** No se implementa ni se concede hasta entonces |
| D-E4-10 | `creado_en` = `ahora` de la instantánea; normalización de cédula/teléfono/correo/nombres. **Revisión:** reglas específicas de 5.2 (`+` solo al inicio del teléfono) | ✅ **Aprobada** (con la aclaración 2 incorporada) |
| D-E4-11 | Modificar `09_integridad.sql`: lista blanca exacta de `banco_app` y 2 controles | ✅ **Aprobada** (la lista blanca será de 5, o de 6 si Juan confirma) |

### Del equipo (D12b / D13) — **PROVISIONALES: NO aprobadas colectivamente**

Se conservan las recomendaciones como **valores provisionales, centralizados en un único lugar** (5.7). Hasta que el equipo decida, no deben presentarse como acordadas.

| ID | Decisión pendiente | Quién | Valor provisional | Tipo |
|---|---|---|---|---|
| D-E4-12 | Edad mínima de registro | Equipo (D12b) | 18 años (máx. 120) | regla |
| D-E4-13 | Formato de cédula y teléfono | Equipo (D12b) | cédula 6–10 dígitos; teléfono 10 nacional / 8–15 internacional con `+` | regla |
| D-E4-14 | Código de referido inexistente o mal formado: ¿error o ignorarlo? | Equipo (D12b) | error `Código de referido inválido` | regla |
| D-E4-15 | Mensajes nuevos (sección 11) | Front + equipo (D13) | los listados | texto |
| D-E4-16 | Mensaje y tratamiento de «sesión inexistente» | Front + Juan (D13) | `Sesión inválida` | texto/integración |
| **D-E4-17** | **Enumeración de usuarios: mensajes de duplicado específicos o genérico** | **Equipo — decisión de NEGOCIO pendiente** | específicos | negocio |
| D-E4-18 | `correoverificado` con la verificación apagada | Equipo | `false` | regla |
| **D-E4-19** | **Bono a referidores bloqueados y límite frente a granjas de cuentas** | **Equipo — decisión de NEGOCIO pendiente** | paga siempre, sin límite | negocio |
| D-E4-20 | Responsabilidades del backend (bcrypt señuelo, comparar antes de `validar_sesion`, no castear `uuid`/`date`) | Juan | informativo | coordinación |

---

## 14. Riesgos y límites

1. **El registro «acuña» dinero simulado** y el bono se presta a granjas de cuentas: por diseño del spec; la mitigación es del backend (y de la decisión D-E4-19).
2. **Reglas provisionales** pueden cambiar: están aisladas en `_reglas_registro()`, `_msg_auth()` y cuatro puntos de código documentados (5.7).
3. **Enumeración** por mensajes de duplicado (D-E4-17, negocio) y por tiempos de respuesta: el backend debe igualar tiempos con bcrypt señuelo.
4. **Capacidad de username:** ≈ 9 900 usuarios por base; más allá, el mensaje de agotamiento.
5. **`READ COMMITTED` obligatorio** (hereda de `_asentar_grupo`).
6. **Configuración regional de la BD:** la validación de nombres de cualquier alfabeto depende de `[[:alpha:]]` con la configuración de la BD (`en_US.utf8`); si se recreara con otra, una prueba lo detecta.
7. **Una transacción larga** del admin sobre el reloj puede retrasar registros (`FOR SHARE`); el `lock_timeout` de 3 s lo acota.
8. **Superusuario:** puede crear usuarios saltándose todo (límite ya documentado; las vistas lo detectan: `usuarios_sin_cuenta`, `bonos_inconsistentes`, saldos).
9. **El mock y el front** tienen diferencias con el contrato (sección 9): no son de BD.

---

## 15. Plan de ejecución (solo cuando des la aprobación final)

E4.1 utilidades puras, reglas y mensajes centralizados (13) → E4.2 `_validar_*`, `obtener_credenciales`, `validar_sesion`, `vista_perfil` (14) → E4.3 `registrar_usuario` (usuario, cuenta, username, cuenta única) → E4.4 ingresos por estratos, `_pagar_bono_referido`, `verificar_correo` (**E4.4b: `datos_reenvio_verificacion` solo si Juan confirma**) → E4.5 `09_integridad.sql` + adaptación de pruebas de E1/E2/E3 → E4.6 pruebas SQL (40–48), conexiones reales y concurrencia (`reales/39`, `40`) → E4.7 mutaciones, documentación (`04-auth.md`), demo de pgAdmin, evidencias (reset + 3 `apply`, suite completa en verde, `git status`). **Una sola entrega al final y parada para tu revisión**, sin commits y sin empezar E5.
