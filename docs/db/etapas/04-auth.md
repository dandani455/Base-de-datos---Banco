# Etapa 4 — Autenticación y registro de usuarios · paquete de entrega

**Estado:** ✅ implementada y verificada; **a la espera de tu auditoría**. Implementa exclusivamente lo del diseño aprobado [04-auth-diseno.md](04-auth-diseno.md) (D-E4-1 a D-E4-8, D-E4-10 y D-E4-11 aprobadas, con tus observaciones). **D-E4-9 sigue PENDIENTE de Juan: `datos_reenvio_verificacion` no se implementó y `banco_app` no tiene `EXECUTE` sobre ella.** **D-E4-12 a D-E4-20 siguen siendo PROVISIONALES del equipo** (no se presentan como aprobadas; D-E4-17 y D-E4-19 son decisiones de negocio pendientes). **Sin commits** (todo sigue sin versionar en `feat/db-core`). No se tocó `front/`, backend, `docs/specs`, `docs/superpowers` ni archivos de otros integrantes. No se comenzó E5. E1, E2 y E3 no se reconstruyeron (ver sección 10 para las únicas modificaciones, mínimas y justificadas).

Contexto: [E1](01-esquema.md) · [E2](02-libro-mayor.md) · [E3](03-reloj.md) · resumen para Juan: [04-resumen-para-juan.md](04-resumen-para-juan.md).

## 1. Qué se entrega

| # | Entregable | Dónde |
|---|---|---|
| 1 | **Scripts SQL** (2 nuevos + 1 ajustado) | `db/sql/13_auth_utilidades.sql`, `14_auth_funciones.sql`; ajustado `09_integridad.sql` (lista blanca de `banco_app`, vista `v_integridad_auth`, columna `controles_auth_fallidos`) |
| 2 | **Pruebas SQL** | `db/tests/40…48_auth_*.test.sql` (9 archivos) |
| 3 | **Conexiones reales y concurrencia** | `db/tests/reales/39_auth_conexiones.sh`, `40_auth_concurrencia.sh` |
| 4 | **Mutaciones** | `db/tests/mutaciones/mutaciones.sh` (M51–M91; opciones `DESDE=N` y `SOLO="M56 M68"`) |
| 5 | **Arnés de pruebas** | `db/tests/harness.sql` (constructores `tests.reg/uid/cod/cta/hash`, `tests.huella_registro`, **inyección de fallos** `tests.instalar_fallas/quitar_fallas/falla`); `helpers.sql` sin cambios |
| 6 | **Pruebas de E1/E2/E3 adaptadas** | `03`, `09`, `10` (inventario y permisos), `reales/37` (margen de tiempo, sección 10) |
| 7 | **Evidencias** | `docs/db/evidencias/04-auth.txt` (suite completa), `04-auth-mutaciones.txt`, `04-auth-aplicacion.txt` (reset + 3 × `apply`), `04-pgadmin-demo.sql` y `04-pgadmin-demo-salida.txt`, `git_status_e4.txt` |
| 8 | **Documentación** | este archivo, el encabezado de `04-auth-diseno.md`, `04-resumen-para-juan.md`, `docs/db/00-entorno.md`, `COMMENT ON` en cada función y vista |
| 9 | **Guía de verificación en pgAdmin** | sección 9 + `04-pgadmin-demo.sql` |

## 2. Resultado de un vistazo

| Verificación | Resultado |
|---|---|
| Suite completa (`db\ctl.cmd test`) | **1604 aprobadas, 0 fallidas** (E1+E2 adaptadas: 837 · E3: 361 · **E4: 406** = 276 SQL + 130 de conexiones reales y concurrencia) |
| Ejecución desde cero | `reset` + 3 × `apply`: **0 errores** (15 archivos; 11 tablas en `public` + `audit.evento`; **47 funciones**; 16 triggers; 2 event triggers; **7 vistas**) |
| Mutaciones | **91 de 91 detectadas** (24 de E2 + 26 de E3 + **41 de E4**) — ver nota sobre M56 y M68 en la sección 7 |
| Integridad | `v_integridad_global.ok = true`; `v_integridad_defensas`: **31 controles, 0 fallidos** (nueva lista blanca de `banco_app`); `v_integridad_auth`: 2 controles, 0 fallidos |
| Permisos por rol | `banco_app`: exactamente 5 funciones; `banco_lector`: ninguna de E4; `banco_dev`: hereda las 5; internas: nadie; `PUBLIC`: nada (sección 6) |
| Conexiones TCP reales | 111 comprobaciones (`reales/39`): conversación del backend, permisos efectivos, 15 fallos inyectados, 4 cortes de conexión, medianoche |
| Concurrencia | 19 comprobaciones (`reales/40`): 0 deadlocks, 0 timeouts, 0 violaciones `UNIQUE` visibles |
| Tablas | `public` sigue con **exactamente 11 tablas**; `audit.evento` en `audit` |
| Usuarios en `banco` | 0 (el seed y los usuarios fijos son de E14) |

## 3. Cómo funciona

```
POST /auth/registro   backend: valida la clave (8, mayúscula, número) y hace bcrypt → registrar_usuario(10 parámetros)
   1 política · 2 presencia · 3 formato (nombres, cédula, correo, teléfono, hash bcrypt, fecha en texto, uuid en texto)   ← sin reloj
   4 UNA instantánea  (SELECT hoy, ahora FROM _reloj_instantanea(): bloqueo FOR SHARE y después el instante)
   5 edad con 'hoy' del banco · 6 referidor (solo CLIENTE) · 7 duplicados (cédula, correo, teléfono)
   8 usuario: username = base + 3 dígitos (30 intentos) y luego 4 dígitos (30)       9 cuenta: '40' + 8 dígitos (reintento por unicidad)
  10 5 INGRESO_SIMULADO por _asentar_grupo: fechas en 5 estratos disjuntos de la ventana [ahora−90 días, ahora−1 min]
  11 bono (solo si hay referidor y la verificación está APAGADA) → _pagar_bono_referido(nuevo, ahora)        12 → {usuario_id, username}
POST /auth/login      obtener_credenciales(username) → bcrypt EN EL BACKEND → validar_sesion(usuario_id) → JWT
cada petición         validar_sesion(usuario_id): estado y rol VIVOS (bloquear con sesión abierta surte efecto en la siguiente petición)
GET /perfil           vista_perfil(usuario_id)      enlace del correo → verificar_correo(usuario_id) (idempotente; paga el bono una vez)
```

Todo ocurre en **una sentencia = una transacción** (`READ COMMITTED`, el nivel por defecto de `pg`; `_asentar_grupo` lo exige).

## 4. Diccionario de funciones

### 4.1 Públicas — `EXECUTE` solo `banco_app` (y `banco_dev` por herencia); `SECURITY DEFINER`, dueño `banco_owner`, `search_path = public, pg_temp`

| Función | Parámetros | Devuelve | Reloj | Errores (P0001) |
|---|---|---|---|---|
| `registrar_usuario` | `p_nombres, p_apellidos, p_cedula, p_correo, p_telefono, p_fecha_nacimiento` **(text)**, `p_password_hash text, p_acepta_politica boolean, p_codigo_referido` **(text)**, `p_verificacion_activa boolean` | `jsonb` `{usuario_id, username}` | **1 instantánea** (tras las validaciones sin reloj) | `Debe aceptar la política de datos` (contrato) y los provisionales de la sección 5 |
| `obtener_credenciales` | `p_username text` | `TABLE(usuario_id uuid, password_hash text, rol text, estado text)`; **0 filas** si no existe; nunca lanza; la **única** que entrega el hash | no | — |
| `validar_sesion` | `p_usuario_id uuid` | `jsonb` `{username, rol, estado}` | no | `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla` (contrato); `Sesión inválida` (provisional) |
| `verificar_correo` | `p_usuario_id uuid` | `void`; idempotente | **1 instantánea** (solo si hay algo que hacer) | `Recurso no encontrado` (contrato) |
| `vista_perfil` | `p_usuario_id uuid` | `jsonb` `{username, numero_cuenta, codigo_referido}` (3 claves, todas texto) | no | bloqueo, `Acceso denegado` (admin), `Sesión inválida` |

### 4.2 Internas (13) — sin `EXECUTE` para nadie salvo el dueño; no son `SECURITY DEFINER` (solo las llaman funciones definer)

| Función | Rol |
|---|---|
| `_reglas_registro()` | **Todos** los valores provisionales y técnicos en UN solo lugar (edad 18–120, cédula 6–10, teléfono 10 / 8–15, intentos de username, prefijo `40`, ventana de 90 días…) |
| `_msg_auth(clave)` | **Todos** los mensajes (4 del contrato exactos + provisionales) en UN solo lugar |
| `_nombre_valido(texto)` | **Validación A** (almacenar): letras de cualquier alfabeto, espacio, apóstrofo, punto, guion y marcas combinantes; sin dígitos de ningún alfabeto |
| `_norm_texto`, `_norm_digitos(texto, permite_+)`, `_norm_cedula`, `_norm_telefono` | Normalización; `+` **solo al inicio del teléfono**, nunca en la cédula |
| `_username_base(nombres, apellidos)` | **Regla B** (generar el username): inicial + primer apellido no partícula, sin tildes; respaldo `u`/`usuario` |
| `_edad_en(nacimiento, hoy)` | Edad con la fecha del banco que recibe |
| `_es_hash_bcrypt(texto)` | Forma `$2a/$2b/$2y$NN$` + 53 caracteres: la BD nunca guarda una clave en claro |
| `_validar_cliente(uuid)`, `_validar_admin(uuid)` | Helpers de autenticación para E5–E12 (matriz rol × estado probada) |
| `_pagar_bono_referido(usuario, ahora)` | **Única** implementación del bono; recibe el `ahora` de la operación (no consulta el reloj); idempotente; sin trigger |

### 4.3 Objetos de integridad (en `09_integridad.sql`)
* `v_integridad_auth` (nueva, 7.ª vista): (1) todo `CLIENTE` tiene su cuenta y ningún `ADMIN` la tiene; (2) `bono_referido_pagado` ⇔ exactamente un grupo `BONO_REFERIDO` en la cuenta del referidor con la cuenta del referido como contraparte.
* `v_integridad_defensas`: +1 control: **`banco_app` ejecuta EXACTAMENTE las 5 funciones públicas** (y `PUBLIC`/`banco_lector` ninguna de ellas).
* `v_integridad_global`: `ok` incorpora `v_integridad_auth`; columna `controles_auth_fallidos` agregada **al final** (compatible con reaplicar el script).

## 5. Decisiones: aprobadas, pendientes y provisionales

| ID | Estado | Dónde queda |
|---|---|---|
| D-E4-1 … D-E4-8, D-E4-10, D-E4-11 | ✅ Aprobadas por el responsable de BD | implementadas |
| **D-E4-9** `datos_reenvio_verificacion` | ⏳ **PENDIENTE de Juan.** No se implementó ni se concedió `EXECUTE`. **Alternativa** si Juan la confirma: añadir en una sub-etapa `14b` la función `datos_reenvio_verificacion(p_username text) → TABLE(usuario_id, correo)` (0 filas si no existe o ya está verificado), su prueba y subir la lista blanca de 5 a 6; si no, no existe | `to_regproc(...)` es NULL (probado en `45` y `reales/39`) |
| D-E4-12 edad mínima 18 / máx. 120 | ⚠️ **Provisional (equipo)** | `_reglas_registro()` |
| D-E4-13 cédula 6–10; teléfono 10 / 8–15 con `+` | ⚠️ Provisional | `_reglas_registro()` |
| **D-E4-14** referido inválido: error o ignorar | ⚠️ Provisional: **error** `Código de referido inválido` | paso 3 y 6 de `registrar_usuario` (un solo literal) |
| **D-E4-15** mensajes nuevos | ⚠️ Provisionales hasta D13 | `_msg_auth()` |
| D-E4-16 `Sesión inválida` | ⚠️ Provisional | `_msg_auth('sesion')` |
| **D-E4-17** duplicados: mensajes específicos o genérico (**enumeración de usuarios; negocio pendiente**) | ⚠️ Provisional: **específicos** (`La cédula/El correo/El teléfono ya está registrado`) | claves `dup_*` de `_msg_auth()`: pasar a un genérico = cambiar 3 literales |
| D-E4-18 `correoverificado` con verificación apagada | ⚠️ Provisional: `false` | rama del bono de `registrar_usuario` |
| **D-E4-19** bono a referidor **bloqueado** (**negocio pendiente**) | ⚠️ Provisional: **paga** | `_pagar_bono_referido`, un único punto |
| D-E4-20 responsabilidades del backend | informativo | `04-resumen-para-juan.md` |

**Mensajes del contrato (exactos):** `Debe aceptar la política de datos`, `Tu cuenta ha sido restringida, contacte con el banco para desbloquearla`, `Acceso denegado`, `Recurso no encontrado`. **Provisionales:** `Datos de registro incompletos`, `Datos de registro inválidos`, `Nombre inválido`, `Apellido inválido`, `Cédula inválida`, `Correo inválido`, `Teléfono inválido`, `Fecha de nacimiento inválida`, `Debes ser mayor de edad para registrarte`, `La cédula ya está registrada`, `El correo ya está registrado`, `El teléfono ya está registrado`, `Código de referido inválido`, `Sesión inválida`, `No fue posible generar el usuario, intenta de nuevo`.

## 6. Garantías conservadas y permisos por rol (verificados, no solo declarados)

| Garantía | Cómo se comprueba |
|---|---|
| Todo lo financiero pasa por `_asentar_grupo` | `42` (el código de `registrar_usuario` y `_pagar_bono_referido` no tiene ningún `INSERT` en `transaccion` ni `UPDATE` de saldos); mutaciones M64–M67, M81 |
| Libro inmutable y saldos solo por E2 | `v_integridad_*` en orden tras miles de registros (`47`, `reales/40`); los saldos del referidor son exactos tras 15 bonos simultáneos |
| Atomicidad | sección 8 |
| Reloj: **una** instantánea por operación y reutilizada | `46` (sección 7) |
| Ninguna función de E4 usa `now()`, `current_date`, `hoy_banco()`, `_ahora_real()`… | `46`: escaneo del código de las 18 funciones; mutaciones M63, M79–M81 |

**Permisos por rol** (`45` con `SET LOCAL ROLE`, `reales/39` con conexiones TCP reales; ninguno depende del superusuario):

| Rol | Las 5 públicas | Las 13 internas | Tablas |
|---|---|---|---|
| `banco_app` | **sí** (probado end-to-end) | `permission denied` (13 × 3 roles) | sin acceso (ni `usuario`, ni `password_hash`, ni el libro, ni auditoría); no puede `UPDATE`/`INSERT`/`DELETE` ni asumir `banco_owner` (conexión real) |
| `banco_dev` | sí (hereda de `banco_app`) | no | solo lectura de vistas |
| `banco_lector` | **no** (`permission denied`) | no | lee `v_integridad_*`, no `password_hash` |
| `PUBLIC` | no | no | — |

## 7. Pruebas y mutaciones

| Archivo | Qué demuestra | Aserciones |
|---|---|---|
| `40_auth_normalizacion` | reglas y mensajes exactos; nombres de cualquier alfabeto; `+` solo al inicio del teléfono y nunca en la cédula; `+57` canónico; username (tildes, ñ, partículas, apóstrofos, respaldo); edad y 29-feb; 19 formas de no-bcrypt | 35 |
| `41_auth_registro` | registro completo, **cada** validación con su mensaje exacto y su orden (política primero), duplicados con otro formato, nombres chino/cirílico/árabe/griego/hebreo almacenados intactos, 150 homónimos, paso a 4 dígitos y **agotamiento**, mensajes que no repiten la entrada, inyección SQL | 51 |
| `42_auth_ingresos` | exactamente 5 grupos de 2 patas; montos enteros en `[min,max]` de `parametro`; **fechas distintas, ascendentes y dentro de 90 días por construcción** (también con `n = 500`, `n = 1`, `n = 0`, `min = max`, decimales); reloj atrasado y adelantado | 26 |
| `43_auth_referidos` | bono con verificación apagada/encendida/NULL; `verificar_correo` ×N = un bono; ADMIN, borrado, bloqueado (D-E4-19); monto de `parametro`; nota y contraparte; los 2 controles de integridad detectan 4 sabotajes | 32 |
| `44_auth_sesion` | `obtener_credenciales`, `validar_sesion` (bloqueo con «sesión abierta» en vivo), `vista_perfil` (**y que no toca nada financiero ni `avanzar_hasta`**), matriz rol × estado de los helpers, el hash solo sale por `obtener_credenciales` | 30 |
| `45_auth_permisos` | rol real: 5 funciones sí/no por rol, 39 combinaciones de internas denegadas, sin acceso a tablas, ACL exacta, detección de 5 concesiones indebidas | 36 |
| `46_auth_reloj` | escaneo del catálogo; **conteo dinámico de lecturas del reloj** (registro = 1 + patas; petición inválida = 0; `verificar_correo` ya verificado = 0); mayoría de edad el día exacto, frontera de medianoche de Bogotá, 29-feb, 120/121 años, reloj manual | 37 |
| `47_auth_aleatorio` | 700 intentos aleatorios (0–3 defectos a la vez) contra un oráculo independiente: mensaje exacto o éxito; cada rechazo deja el estado intacto; cada éxito escribe 1+1+10(+2) filas | 8 |
| `48_auth_atomicidad` | fallo inyectado en **cada una de las 12 patas** del registro con bono (después de aplicar su saldo), en la cuenta, el usuario, la bandera del bono y en `verificar_correo` (4 puntos); estado intacto y reintento correcto | 21 |
| `reales/39_auth_conexiones` | conversación del backend por TCP; errores con SQLSTATE `P0001`; TimeZone irrelevante; `REPEATABLE READ` rechazado; permisos efectivos; **15 fallos inyectados y 4 cortes de conexión sobre el estado confirmado**; **medianoche** con tiempo inyectado | 111 |
| `reales/40_auth_concurrencia` | 8 sesiones misma cédula (1 gana); mismo correo y teléfono en formatos distintos; 12 homónimos; 10 `verificar_correo` simultáneos = un bono; 15 referidos simultáneos con saldo exacto; 36 registros ∥ 75 cambios de reloj | 19 |

**Mutaciones M51–M91 (41):** cada una rompe una defensa de E4 a propósito y exige que alguna prueba falle: normalizadores, validación de nombres, edad, política, duplicados, hash en claro, ingresos (fechas iguales o fuera de ventana), bono (sin bandera, sin comprobar pago, sin bloqueo, con verificación activa, NULL), referido inválido o de ADMIN, bloqueo de sesión, credenciales, helpers, reloj (doble instantánea, `now()`, reloj de pared en el bono, edad con la fecha del sistema), commit parcial, reintento de username, valores centralizados, y todas las concesiones indebidas de permisos. **Resultado: 91/91 detectadas** (`04-auth-mutaciones.txt`).
*Nota honesta:* en la primera corrida **M56** y **M68** *no* se detectaron porque estaban mal definidas (eran **mutantes equivalentes**): M56 quitaba el rango de dígitos ASCII, que el filtro `[[:alpha:]]` ya rechaza; M68 quitaba un `FOR UPDATE` redundante porque `UPDATE usuario` ya serializa. Se rehicieron (M56: dígitos **no ASCII**, que `[[:alpha:]]` sí acepta; M68: sin bloqueo **y** con el correo marcado al final, lo que sí permite pagos simultáneos duplicados: 10 bonos en vez de 1) y quedaron detectadas.

## 8. Atomicidad (observación E de la auditoría)
Una llamada es una transacción: `registrar_usuario` revierte **usuario, cuenta, ingresos, bono y bandera** ante cualquier fallo, incluso tras escribir patas del libro. Inyección de fallos solo en `banco_test` (trigger `trg_zz_falla`, regla en el parámetro de sesión `tests.falla`):
* `48` (transaccional): `tx:1…12` (cada pata, tras aplicar su saldo), `usuario`, `cuenta`, `bono_flag` (después de escribir las patas del bono); `verificar_correo`: `tx:1`, `tx:2`, `bono_flag`, `verificar`. Tras cada fallo: huella (usuarios, cuentas, patas, saldos, banderas) idéntica, saldo del referidor intacto, integridad en orden y **reintento exitoso**.
* `reales/39`: los mismos fallos por TCP (estado **confirmado**), más `corte:2/7/11/12` (`pg_terminate_backend`) a mitad del registro y entre los dos tramos del bono; ninguna sesión queda colgada.
* Mutación M82 (se traga el fallo del bono y deja un commit parcial) la detecta `48`.

## 9. Guía de verificación desde pgAdmin
Prerrequisito: `db\ctl.cmd up` y `db\ctl.cmd apply` (aplica 00–14). Conexiones: **administración (postgres)**, **banco_dev**, **banco_app**, **banco_lector**. Base `banco`, *Tools → Query Tool*.

### A. Inventario (administración)
```sql
-- 1) Las 5 funciones públicas (definer, ACL: solo banco_owner y banco_app) y las 13 internas (solo banco_owner)
SELECT proname, pg_get_userbyid(proowner) AS dueno, prosecdef AS definer, proacl
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace
   AND proname IN ('registrar_usuario','obtener_credenciales','validar_sesion','verificar_correo','vista_perfil',
                   '_validar_cliente','_validar_admin','_pagar_bono_referido','_reglas_registro','_msg_auth','_nombre_valido',
                   '_norm_texto','_norm_digitos','_norm_cedula','_norm_telefono','_username_base','_edad_en','_es_hash_bcrypt')
 ORDER BY prosecdef DESC, proname;
-- 2) ¿Quién ejecuta qué? banco_app = 5; banco_lector = ninguna de E4
SELECT r.rol, string_agg(p.proname, ', ' ORDER BY p.proname) AS ejecuta
  FROM (VALUES ('banco_app'), ('banco_dev'), ('banco_lector')) r(rol)
  JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND has_function_privilege(r.rol, p.oid, 'EXECUTE')
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
 GROUP BY r.rol ORDER BY 1;
-- 3) La función de reenvío NO existe (D-E4-9 pendiente de Juan)
SELECT to_regproc('public.datos_reenvio_verificacion') AS reenvio_existe;
-- 4) Reglas y mensajes centralizados
SELECT jsonb_pretty(public._reglas_registro());
SELECT public._msg_auth('politica'), public._msg_auth('dup_cedula');
```
*Esperado:* 5 filas con `definer = t` y 13 con `f`; `banco_app` y `banco_dev` = las 5; `banco_lector` = solo `_plantillas_validas, ahora_banco, hoy_banco` (de E2/E3); `reenvio_existe` vacío; las reglas provisionales a la vista.

### B. Verificación independiente (también con **banco_lector** y **banco_dev**)
```sql
SELECT * FROM public.v_integridad_global;                                  -- ok = true, controles_auth_fallidos = 0
SELECT * FROM public.v_integridad_auth;                                    -- 2 controles, ok = true
SELECT control, ok FROM public.v_integridad_defensas WHERE control LIKE 'banco_app ejecuta%';   -- ok = true
SELECT count(*) AS defensas_en_error FROM public.v_integridad_defensas WHERE NOT ok;            -- 0 (31 controles)
```

### C. Demostración completa sin dejar datos (administración)
Abrir `docs/db/evidencias/04-pgadmin-demo.sql` y ejecutar **completo con F5** (va dentro de `BEGIN … ROLLBACK`; resultados en **Messages**). Muestra: registro con los 5 ingresos (fechas distintas y ascendentes), nombre chino intacto y username de respaldo, `+57` canónico, **cada** rechazo con su mensaje (política, clave en claro, referido malformado, fecha imposible, menor de edad, inyección SQL, cédula y teléfono duplicados con otro formato), login (`obtener_credenciales` → `validar_sesion`), **bloqueo con la sesión abierta**, perfil, bono con verificación apagada/encendida y **tres** verificaciones = un solo bono, y la prueba de permisos con roles. Salida real: `04-pgadmin-demo-salida.txt` (ejecutada con `psql`).

**Verificación real en la interfaz de pgAdmin (2026-11-23):** en el Query Tool de la conexión *administración (postgres)* (base `banco`) se ejecutó con F5 una consulta de verificación (la de A.2 + B condensada); resultado: `banco_app_ejecuta = obtener_credenciales, registrar_usuario, validar_sesion, verificar_correo, vista_perfil` · `defensas_en_error = 0` · `global_ok = true` · `auth_ok = 2` (captura: `capturas-pgadmin/e4-verificacion-pgadmin.jpg`). *Alcance honesto:* en la interfaz se ejecutó solo esa consulta; la demostración completa (C) se ejecutó con `psql` por su tamaño.

### D. Con **banco_app** (el backend): solo funciones
```sql
SELECT * FROM public.usuario;                              -- ERROR: permission denied for table usuario
SELECT password_hash FROM public.usuario;                  -- ERROR: permission denied
SELECT public._pagar_bono_referido(gen_random_uuid(), now());   -- ERROR: permission denied for function _pagar_bono_referido
SELECT public.registrar_usuario('Ana','Gil','8123456','ana.gil@mail.co','3123456789','1990-05-17',
       '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', true, NULL, true);   -- OK: {"username": "agil###", "usuario_id": ...}
SELECT * FROM public.obtener_credenciales('agil123');      -- (con el username devuelto) usuario_id | hash | CLIENTE | ACTIVO
```
*Nota:* un usuario creado desde pgAdmin **queda** guardado; bórralo con **administración**: `DELETE FROM public.usuario WHERE cedula = '8123456';` (la cascada elimina su cuenta y deja un evento `CUENTA_BORRADA` en la auditoría).

### E. Con **banco_lector**
`SELECT * FROM public.v_integridad_auth;` funciona; `SELECT public.validar_sesion(gen_random_uuid());` y `SELECT password_hash FROM public.usuario;` dan *permission denied*.

## 10. Desviaciones respecto al diseño aprobado (todas con su porqué)

| # | Desviación | Porqué / efecto |
|---|---|---|
| 1 | **Se añadió la función interna `_nombre_valido()`** (13 internas; **47** funciones en total, el diseño decía 12 y 46) | En esta configuración regional (`en_US.utf8`) `[[:alpha:]]` también acepta **dígitos no ASCII** (p. ej. `٣`); se excluyen explícitamente y la validación queda aislada y probada (31 casos) |
| 2 | **`nombre_min` = 1** (el diseño decía 2) | Existen apellidos de un solo carácter (p. ej. 王); con 2 se rechazaba un nombre real (descubierto en el primer ensayo con `李明 / 王`) |
| 3 | `v_integridad_global.ok` incorpora `v_integridad_auth` y se agrega la columna `controles_auth_fallidos` **al final** | Mantiene `CREATE OR REPLACE VIEW` idempotente sobre una base ya aplicada; el diseño hablaba de «2 controles» sin precisar dónde |
| 4 | **`datos_reenvio_verificacion` no se implementó** | D-E4-9 pendiente de Juan (instrucción expresa): `banco_app` ejecuta 5 funciones, la lista blanca es de 5 |
| 5 | ✅ **CONFIRMADA por el responsable de BD (2026-11-23).** **Regla B del username con respaldo `u`/`usuario`** (tal como la aprobó el diseño) frente a tu instrucción de implementación «si un nombre no permite generar un username válido debe producirse un error controlado» | Son compatibles si se lee así: el algoritmo aprobado **siempre produce** un username (respaldo) y el error controlado `No fue posible generar el usuario, intenta de nuevo` ocurre por **agotamiento** (probado en `41`). Un nombre en otro alfabeto **se registra** y se almacena intacto. **Confirmado: los nombres sin letras latinas se registran con el username de respaldo y el nombre original se conserva íntegro; se mantienen la unicidad del username y el error controlado por agotamiento. No requiere cambios.** |
| 6 | **Modificada una prueba de E3** (`reales/37_reloj_concurrencia.sh`): la operación lenta pasa de 2,5 s a 3,0 s | En la línea base de esta etapa falló **una vez** (`A: el cambio del admin ESPERÓ…`, 1 de 4 corridas) por un margen de ~0,3 s; repetida, pasó. No es un defecto de E3 sino una prueba sensible al tiempo; el margen se ensanchó |
| 7 | **Pruebas de E1/E2 adaptadas** (`03`, `09`, `10`): inventario 47 funciones y 7 vistas; la prueba de «ninguna función ejecutable por `banco_app`» pasa a «exactamente las 5 públicas»; `09` reaplica 00–14 | E4 concede por primera vez `EXECUTE` a `banco_app` (esperado en el diseño); conservan su significado |
| 8 | `tests.trg_falla` (inyección de fallos) es `SECURITY DEFINER` | Para poder cortar la conexión de otro rol con `pg_terminate_backend`; existe **solo en `banco_test`** |
| 9 | `mutaciones.sh`: opciones `DESDE=N` y `SOLO="M56 M68"` | Repetir un subconjunto sin correr las 91 |
| 10 | `registrar_usuario` devuelve `{usuario_id, username}` (el contrato dice `{username}`) | Aprobado (D-E4-1/D-4): el backend necesita `usuario_id` para firmar el token de verificación y **responde solo `{username}` al front** |

## 11. Límites (honestidad)
* **Superusuario:** puede crear usuarios saltándose todo (límite ya documentado); `v_integridad_auth` y las defensas lo **detectan**, no lo impiden.
* **El registro «acuña» saldo simulado** (spec): un backend sin rate limit/captcha permite granjas de cuentas y bonos (D-E4-19 pendiente de negocio).
* **Enumeración:** los mensajes de duplicado revelan que una cédula/correo/teléfono existe (D-E4-17 pendiente). El backend debe usar el bcrypt «señuelo» y responder igual con 0 filas.
* **Capacidad de username:** ≈ 9 900 por base (`jperez`).
* **La validación de nombres depende de la configuración regional de la BD** (`[[:alpha:]]`): una prueba lo verifica y falla con un mensaje claro si la BD se recreara con otra.
* **Solo se aceptan marcas combinantes U+0300–U+036F** (acentos descompuestos); otras marcas (p. ej. diacríticos árabes o devanagari) se rechazan en `_nombre_valido`: no se introdujeron transliteraciones ni listas complejas sin autorización.
* `READ COMMITTED` obligatorio (heredado de `_asentar_grupo`); con `REPEATABLE READ` el registro se rechaza con un mensaje claro (probado).
* Las pruebas que dependen del reloj real se repiten si fallan una sola vez justo en la medianoche de Bogotá (documentado en E3).

## 12. Cómo ejecutar todo

```powershell
db\ctl.cmd up
db\ctl.cmd reset -Yes ; db\ctl.cmd apply ; db\ctl.cmd apply ; db\ctl.cmd apply   # desde cero + 3 aplicaciones
db\ctl.cmd test -Evidence 04-auth            # suite completa (≈ 4,5 min): SQL + conexiones reales + concurrencia
db\ctl.cmd test 41                           # solo las pruebas que empiezan por 41 (SQL y reales/)
docker compose -f db\compose.dev.yml exec -T db sh -c "tr -d '\r' < /work/tests/mutaciones/mutaciones.sh | sh -s"             # las 91 mutaciones
docker compose -f db\compose.dev.yml exec -T db sh -c "tr -d '\r' < /work/tests/mutaciones/mutaciones.sh | DESDE=51 sh -s"   # solo las de E4
```

## 13. Lista de verificación

- [x] 13–14 aplican desde cero y 3 veces seguidas sin errores; `09` de pruebas confirma que el catálogo queda idéntico
- [x] `public` = 11 tablas; `audit.evento` en `audit`; 47 funciones, 16 triggers, 7 vistas
- [x] `registrar_usuario` solo crea CLIENTE; sin parámetros para forzar username/cuenta; prefijo `40` + 8 dígitos
- [x] Parámetros `text` para fecha de nacimiento y código de referido; salidas `jsonb`
- [x] 5 ingresos: enteros, fechas distintas, ascendentes y dentro de 90 días por construcción, solo por `_asentar_grupo`
- [x] Bono solo en `_pagar_bono_referido` (sin trigger), bandera + bloqueo + libro en una transacción
- [x] La BD rechaza todo hash que no sea bcrypt
- [x] Nombres de cualquier alfabeto almacenados intactos; username con regla propia; `+` solo al inicio del teléfono
- [x] `vista_perfil` sin `avanzar_hasta` (desviación consciente, documentada y probada)
- [x] `datos_reenvio_verificacion` NO implementada; D-E4-9 pendiente de Juan
- [x] Una instantánea por operación; ninguna función de E4 usa el reloj del sistema (escaneo + conteo dinámico)
- [x] Atomicidad con fallos inyectados en cada pata, la bandera, la cuenta, el usuario y cortes de conexión
- [x] Permisos por rol real (TCP): `banco_app` 5 funciones, lector ninguna, internas nadie, sin tablas
- [x] Mutaciones 91/91; regresión E1–E3 completa (1604/0)
- [x] No se tocó front/backend; no se comenzó E5; sin decisiones financieras ni del equipo adelantadas; sin commits

**Detenido. Espero tu auditoría; no se comenzó E5.**
