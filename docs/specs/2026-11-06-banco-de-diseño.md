# Diseño — Banco Digital (Proyecto Bases de Datos)

Fecha: 2026-11-06 · Equipo: Daniel García, Daniel Monterroza, Juan Marin, Jose Samur ·
Estado: **BORRADOR PARA APROBACIÓN**

---

## 1. Intento y por qué

Proyecto universitario de Bases de Datos: una **página de banco funcional** con clientes reales
que se registran, transferen dinero, crean bolsillos, CDTs y créditos. El **core de negocio vive
completamente en PostgreSQL** (funciones, triggers y vistas — parte evaluable del curso), un
backend delgado que solo traduce peticiones HTTP a llamadas de la BD, y un frontend React.

**El evento que define el diseño:** el profesor **apagará el contenedor de la BD en la demo**.
La app debe sobrevivir: la página no se cae, y toda acción que necesite la BD muestra un
**error controlado** ("Error de conexión, estamos trabajando para solucionarlo"), nunca una
pantalla fea ni un crash. Decisión de producto: **sin caché de datos** (un banco no muestra
saldos viejos — si no hay BD, no hay lectura).

**El segundo evento:** los profesores evalúan **funciones y triggers de la BD**. Por eso el
backend está prohibido de tener lógica de negocio: es una capilla, y la inteligencia vive en
Postgres.

## 2. Metas / No-metas / Anti-metas

**Metas:**
- Todo dato dinámico (usuarios, balances, transacciones, CDTs, créditos, tasas) vive en la BD.
  Nada hardcoded — el front solo trae textos de marketing y fotos de la página informativa.
- Un banco "real": transferencias entre clientes reales por número de cuenta, CDTs con
  rentabilidad diaria, créditos con plan de cuotas y abonos a capital, bolsillos tipo NU.
- Panel admin con poder de operar el banco: gestionar usuarios, inyectar balance, y
  **manipular el tiempo** para probar intereses sin esperar días reales.
- Deploy completo en Docker Compose: un solo `docker compose up` y todo corre.

**No-metas (explícitamente fuera):**
- No Supabase (regla del curso) — PostgreSQL propio en Docker + pgAdmin 4.
- No apps móviles, no notificaciones push, no correos que no sean la verificación de registro.
- No puntaje/score de crédito (decidido: fuera por simplicidad).
- No retiro anticipado de CDTs (ni con penalización: simplemente no existe la opción).

**Anti-metas (esto sería un fracaso aunque funcione):**
- Lógica de negocio en el backend o en el front (lo evaluable es la BD).
- Datos quemados en el front o IDs secuenciales visibles en URLs.
- Un crash o pantalla fea cuando la BD esté apagada.
- Contraseñas en claro en cualquier parte, o credenciales de la BD en el navegador.

## 3. Restricciones y decisiones ya tomadas

| Decisión | Valor | Quien la tomó |
|---|---|---|
| Base de datos | PostgreSQL (Docker, con pgAdmin 4) | Requisito curso |
| Backend | Node.js + Express + TypeScript | Daniel |
| Frontend | React + Vite + TypeScript | Daniel |
| Deploy | Docker Compose: `db` + `pgadmin` + `backend` + `front` | Daniel |
| Correo (verificación registro) | Resend, con flag para apagar | Daniel |
| IDs | UUID en todas las entidades | Daniel |
| Reloj del banco | Toggle real/manual, **solo avanza, nunca retrocede** | Daniel |
| Error de BD caída | HTTP 503 desde el backend; front lo pinta bonito | Daniel |
| Tasas de negocio | Editables desde el panel admin / tablas de la BD | Daniel |

## 4. Arquitectura

```
┌──────────┐   fetch (JWT httpOnly)   ┌─────────────┐   pg (1 solo pool)   ┌──────────────┐
│  front   │ ───────────────────────► │   backend   │ ───────────────────► │ postgres db  │
│ (nginx)  │                          │ (Express TS)│  SELECT funcion(...) │              │
└──────────┘                          └─────────────┘                      └──────────────┘
                                             │                                     │
                                             │ si la BD no responde: 503           │
                                             │                                     ▼
                                     ┌───────────────────────────────────┐  ┌───────────┐
                                     │ regla única de fallas:            │  │  pgAdmin  │
                                     │ cualquier error con la BD →       │  │  (puerto  │
                                     │ 503 {error:"sin_conexion"}        │  │   5050)   │
                                     └───────────────────────────────────┘  └───────────┘
```

- **Front → Backend**: sesión por cookie httpOnly con JWT (el token nunca toca el localStorage).
- **Backend → BD**: un solo pool de conexiones `pg`; cada endpoint ejecuta **funciones o vistas**
  de la BD (`SELECT * FROM hacer_transferencia(...)`, `SELECT * FROM vista_dashboard(...)`).
- **pgAdmin 4**: para que el equipo (y el profesor) inspeccionen la BD; también es la herramienta
  con la que el equipo se encarga de funciones/triggers.

### 4.1 Contratos entre capas

- **Front nunca habla con la BD**, ni siquiera por accidente: no hay cadena de conexión en el
  bundle. Solo conoce el dominio del backend.
- **Backend**: solo sesiones, hash de contraseñas (bcrypt), rate limit de login, y el mapeo
  único de errores `503`. Está **prohibido** calcular intereses, saldos, o escribir SQL con
  lógica de negocio.
- **BD**: dueña de los datos, de las reglas y de la verdad. Validación, transacciones atómicas,
  auditoría.

## 5. Modelo de datos (tablas)

Todas con `id UUID` (generadas por la BD, `gen_random_uuid()`), montos en `NUMERIC(18,2)`
(COP), fechas con zona y todo lo de unicidad al nivel de la BD:

1. **`usuario`** — `id, username (UNIQUE), password_hash, nombres, apellidos, cedula (UNIQUE),
   correo (UNIQUE), telefono (UNIQUE), fecha_nacimiento, rol ('CLIENTE'|'ADMIN'),
   estado ('ACTIVO'|'BLOQUEADO'), correoverificado boolean, codigo_referido (UNIQUE),
   referido_por (UUID → usuario, nullable), creado_en`.
2. **`cuenta`** — `id, usuario_id (FK UNIQUE), numero_cuenta (UNIQUE, 10 dígitos), balance`.
3. **`bolsillo`** — `id, cuenta_id (FK), nombre, balance, ultimo_cobro (date)`.
4. **`cdt`** — `id, cuenta_id (FK), nombre, monto, tasa_anual (copiadas del tipo al crear),
   fecha_inicio, fecha_fin, generado_acumulado, ultimo_cobro (date), estado ('ACTIVO'|'CERRADO')`.
   *Al crear se copian tasa/plazo/monto: si el admin cambia tasas después, los CDTs vivos no cambian.*
5. **`cdt_definicion`** — los "tipos" de CDT ofertados: `id, nombre, plazo_dias, tasa_anual`.
   **Editable por el admin → es el control de "tasas de CDT editables".**
6. **`credito_producto`** — `id, nombre, descripcion, tasa_anual (editable admin), monto_min,
   monto_max, plazo_max_meses, tope_absoluto (nullable), multiplicador_balance (nullable),
   aplica_regla_edad boolean`. Los 4 productos de la §7 nacen como filas de esta tabla.
7. **`credito`** — `id, cuenta_id, producto_id, monto, tasa_anual (copiada), plazo_meses,
   fecha_desembolso, capital_pendiente, descuento_automatico (boolean, default false),
   mora_acumulada, estado ('ACTIVO'|'PAGADO')`.
8. **`cuota`** — `id, credito_id, numero, valor_cuota_original, capital_pagado, intereses_pagados,
   fecha_pago, pagada boolean`. El plan completo se genera **al desembolsar** (función de BD).
9. **`transaccion`** — la bitácora universal: `id, fecha, tipo (enum), monto, nota, saldo_previo,
   saldo_posterior, cuenta_id, bolsillo_id (nullable), contraparte (nullable: otra cuenta o 'BANCO'),
   credito_id / cdt_id (nullable, según tipo)`. **Todo movimiento de dinero escribe aquí
   automáticamente vía triggers** — es lo que produce "el banco tal te ha enviado $X" sin que
   nadie lo programe dos veces.
   Tipos: `DEPOSITO_BANCO`, `ENVIO`, `RECIBO`, `BOLSO_INGRESO`, `BOLSO_RETIRO`, `BOLSO_MOVIMIENTO`,
   `CDT_CREACION`, `CDT_VENCIMIENTO`, `INTERES_CDT`, `INTERES_BOLSO`, `CREDITO_DESEMBOLSO`,
   `CREDITO_CUOTA`, `CREDITO_ABONO`, `CREDITO_MORA`, `BONO_REFERIDO`, `INGRESO_SIMULADO`,
   `AJUSTE_ADMIN`.
10. **`reloj`** — una sola fila: `id, usar_fecha_real boolean (default true), fecha_sistema date`.
    **La fecha del banco.** Los ingresos por fecha/hora de las transacciones de pruebas se generan
    con el reloj al crearlas (fechas pasadas aleatorias alrededor de hoy).
11. **`parametro`** — una sola fila con parámetros globales editables por el admin:
    `tasa_mora_anual` (la tasa de mora de los créditos).

Reglas de integridad vivas en la BD: `UNIQUE(cedula)`, `UNIQUE(correo)`, `UNIQUE(telefono)`,
`UNIQUE(codigo_referido)`, `CHECK` en montos > 0, transferencias entre cuentas existentes
validadas con FK, y el bloqueo **por tipo de crédito vivo** verificado en función.

## 6. El reloj del banco (diseño central)

- `reloj.usar_fecha_real = true` → el "hoy" del banco es hoy de verdad.
- `= false` → el "hoy" es `fecha_sistema`, que el admin puede **avanzar** (nunca retroceder;
  trigger de la BD lo rechaza con error si intenta ir atrás).
- **Todas las fechas de negocio** (vencimientos de CDT, cuotas, fechas de transacciones nuevas)
  se calculan contra el "hoy" del reloj, no contra `NOW()`.

## 7. Reglas de negocio (viven TODAS en funciones de la BD)

### 7.1 Registro de un usuario
- Campos: nombres, apellidos, cédula, correo, teléfono, fecha de nacimiento, contraseña,
  aceptar política de datos (si no la acepta, no se registra), y **código de referido opcional**.
- La BD genera: `username` = primera letra del nombre + primer apellido + 3-4 dígitos aleatorios,
  con verificación de unicidad y regeneración (ej: `jperez483`); `codigo_referido` UUID aparte del
  username; `numero_cuenta` de 10 dígitos único; `rol=CLIENTE`, `estado=ACTIVO`.
- La **contraseña** se hashea en el backend (bcrypt, con salt) y la guarda la BD ya hasheada.
- Al crearse, la función genera **5 transacciones `INGRESO_SIMULADO`** con montos al azar entre
  $10.000 y $1.000.000 cada una, con **fecha y hora aleatorias en el pasado** — la cuenta nace
  con vida y con balance real acumulado.
- Si venía con `referido_por`, cuando el nuevo usuario se verifica por correo, la BD abona al
  referidor **$50.000 COP** como `BONO_REFERIDO` ("Bono por referir a <nombre>"). El código de
  referido es **UUID, visible en el perfil**, y el registro con referido llega por
  `?ref=<uuid>` en la URL (el front lo guarda para enviarlo en el registro). **Con la verificación
  de correo desactivada (flag), el bono se paga igual al completar registro.**

### 7.2 Login y bloqueo
- Entrada: `username` + `password` (no se permite login por correo: el username autogenerado es
  la llave del banco).
- Si `estado='BLOQUEADO'`: mensaje exacto *"Tu cuenta ha sido restringida, contacte con el banco
  para desbloquearla"*. No puede logear.
- La sesión se guarda en **cookie httpOnly de JWT**. El backend la valida contra la BD en cada
  petición (rol y estado vivo, no en el token, para que desbloquear/bloquear sea inmediato).
- **Rate limit de login** en el backend y bcrypt en la contraseña → la parte anti-fraude que se
  pidió; el resto lo resuelven las `UNIQUE` de la BD.

### 7.3 Envíos entre cuentas (estilo Bancolombia)
- Cada cuenta tiene su **número de cuenta** (10 dígitos) visible en el perfil del usuario.
- El envío pide **número de cuenta destino** + monto + nota. Antes de confirmar, el front pide
  el **nombre del destinatario** para que el usuario vea a quién le envía ("¿Envías a Juan
  Pérez?").
- **Origen del dinero**: por defecto el balance principal, con selector de bolsillo si el usuario
  quiere enviar desde uno.
- Validación y ejecución: **una sola función atómica en la BD** (`hacer_transferencia`),
  que verifica saldo suficiente, cuenta y bolsillo origen existentes, y destino real —
  hace el débito/crédito en una transacción SQL y en un solo `INSERT` de transacción por lado.

### 7.4 Bolsillos (estilo NU, mini-CDT)
- **Rentabilidad fija 12% anual (1% mensual)**, generada **diaria** (tasa diaria = anual/365).
- Se pueden crear varios (con nombre propio, "viajes", "emergencias", etc.), mover dinero
  cuenta↔bolsillo, entre bolsillos, y **retirar** a la cuenta principal (salir).
- Para hacer transferencias entre usuarios, los bolsillos pueden ser el origen (con selector).
- El interés diario de cada bolsillo se genera con **cobro lazy** descrito en §6.

### 7.5 CDTs
- **Definiciones ofertadas** (tabla `cdt_definicion`, editable por el admin: **tasas CDT
  editables**): nombre, plazo en días, tasa anual. Ej: 6-12-24-36 meses con tasas mayores a más plazo.
- Creación: el usuario elige monto + definición; el monto **sale del balance principal** y queda
  bloqueado en el CDT hasta vencimiento.
- **Rentabilidad diaria** = tasa_anual/365 × monto, generada día a día con cobro lazy; el panel
  muestra lo acumulado y el tiempo restante.
- **Al vencer** (cuando el reloj pasa `fecha_fin`): devuelve al principal **monto + total
  generado**, y el CDT pasa a `CERRADO` (queda como "historial" del panel).
- **No existe retiro anticipado.**

### 7.6 Créditos — los 4 productos con sus reglas

| Producto | Monto | Plazo máximo | Tope de monto |
|---|---|---|---|
| Libre inversión | a voluntad | **2 años (24 m)** | **$30M fijo** (sin multiplicador) |
| Vehículo | **$50M – $200M** | 10 años (120 m) | = del rango |
| Educación | **$1M – $100M** | 20 años (240 m) | = del rango |
| Inmuebles | a voluntad | **30 años (360 m)** | 100× balance, **tope $2.000M** |
- **Regla de edad (solo inmuebles):** `edad_actual + plazo_años ≤ 70`. Con alguien de 43 años, el
  selector de plazo se trunca a 27 años. La BD lo aplica al listar ofertas **y** al validar la
  solicitud.
- **Un crédito vivo por producto**: si ya existe un "vehículo" vigente, no se permite otro
  vehículo (la función lo rechaza). Otros productos sí siguen disponibles a la vez.
- **Balance total** para los topes se calcula así: **(balance principal + suma de bolsillos +
  suma de CDTs activos) − suma de capital_pendiente de créditos**. Los créditos desembolsados
  entran al balance pero su deuda lo compensa — se auto-neutralizan; los topes no se explotan
  por tomar créditos.
- **Desembolso instantáneo**: sin cola de aprobación — al solicitar un crédito, la BD valida
  las reglas, y si pasan, `CREDITO_DESEMBOLSO`: el monto entra al balance principal,
  y la BD genera el **plan de cuotas completos** con amortización francesa (cuota fija):
  `cuota = P·i·(1+i)^n / ((1+i)^n − 1)`, con `i = tasa_anual/12` mensual.
- **Mora**: una cuota pasada de fecha e impaga entra en **mora** — se acumula diariamente
  (sobre el valor de la cuota, con la `tasa_mora_anual` global editable por el admin, de la
  tabla `parametro`) por todo el tiempo que quede impaga, y se ve en el panel como
  "mora acumulada". **No hay descuento automático al pasar la fecha**; solo si el usuario
  activó **"descuento automático"** en ese crédito, el cobro lazy debita la cuota cuando pasa
  su fecha y hay saldo disponible.
- **Cobro de cuota**: el usuario paga desde el principal (función de BD, genera
  `CREDITO_CUOTA`).
- **Abonos anticipados**: el usuario puede abonar a capital en **cualquier momento**: la BD cobra
  primero los intereses acumulados del mes (los "impuestos del mes") y **el resto baja el
  capital**, recalculando las cuotas restantes con el mismo plazo y la misma tasa, cuota nueva
  menor. Genera `CREDITO_ABONO`.

### 7.7 Panel admin
- **Usuarios**: lista con **búsqueda** por nombre/cédula/correo/número de cuenta; detalle con
  datos de registro, balance total desglozado (principal + bolsillos + CDTs + créditos),
  historial y estado. Acciones: **bloquear** con mensaje de login de §7.2, **desbloquear**,
  y **borrar** usuario (con cascada de sus productos).
- **Añadir balance**: usuario + monto + nota; la BD escribe `AJUSTE_ADMIN` con la nota
  ("el banco ha enviado..." tal como la nota lo escriba) y aplica al balance.
- **Reloj**: toggle `usar_fecha_real`. Apagado → elegir `fecha_sistema`, **solo se puede
  adelantar** (trigger: rechazar retrocesos con un mensaje de error).
- **Tasas**: editar tasas por definición de CDT, tasa por producto de crédito y tasa de mora
  (de `parametro`). Nace de las tablas, no del código. Los CDTs/creditos **ya creados no
  cambian** (tienen su tasa copiada).

## 8. Cobro lazy (trigger de rentabilidad, el detalle que hace que todo funcione)

- Cada producto que genera interés guarda su **`ultimo_cobro`** (bolsillo, cdt) y los créditos
  su fecha de interés acumulado.
- **Cada vez que un cliente consulta** su dashboard, sus CDTs, sus bolsillos, sus créditos o hace
  cualquier operación de escritura (envío, abono, creación): la función correspondiente corre
  primero `avanzar_hasta(hoy_reloj)`, que:
  1. Por bolsillo: para días desde `ultimo_cobro+1` hasta hoy — suma interés diario, con un
     único `INSERT` de transacción `INTERES_BOLSO` por bolsillo-día (o resumen por día — decisión
     de implementación).
  2. Por CDT: lo mismo (`INTERES_CDT`), y al llegar `fecha_fin`, lo cierra y devuelve el monto
     al principal.
  3. Para créditos: revisa cada cuota que quedó en los días saltados — si el crédito tiene
     "descuento automático" y hay saldo, la debita (`CREDITO_CUOTA`); si no, la marca
     **vencida** y empieza a acumularle mora diaria (`CREDITO_MORA`). El interés de mes
     corriente se acumula igual para el "interés corriendo" del panel.
- **Consecuencias de este diseño** (lo que importa de cara a la demo):
  - Si la BD está apagada horas/días, al regresar el próximo primer acceso calcula todos los
    días pendientes de una vez. **Nada se pierde.**
  - Si el admin adelanta el reloj 30 días, el próximo acceso genera los 30 días de rentabilidad
    de golpe. El botón de pruebas de intereses funciona al instante.
  - El reloj **no retrocede**, así que no hay que deshacer intereses.

## 9. Seguridad y control de acceso por URL

- Toda entidad con UUID — no hay IDs secuenciales a adivinar.
- Toda ruta del backend para un cliente valida **sesión + propiedad**: si pediste un recurso que
  no es de tu cuenta → `403`. No importa si cambias la URL a mano.
- Las rutas de admin piden `rol='ADMIN'` sobre la sesión del usuario (leído de la BD en cada
  petición).
- Contraseñas: bcrypt con salt (10-12 rondas). Regla mínima: mínimo 8 caracteres, 1 mayúscula,
  1 número.
- Rate limit del login en el backend (por IP y por usuario).
- La cookie de sesión: `httpOnly`, `sameSite=lax`, `secure` en desbloqueo de producción.
- La cadena de conexión a la BD **solo existe en el backend** — el front no la conoce nunca.

## 10. El apagón (la demo del profesor)

- `docker compose stop db` → la BD cae.
- **El backend no crashea**: el pool de conexiones empieza a fallar en cada intento.
  La regla única: cualquier error de conexión de la BD → **el backend responde 503 con
  `{error:"sin_conexion"}`** y no se cae.
- **El front** tiene **un solo catch en su cliente fetch** que, al ver 503 (y solo 503),
  muestra en cualquier panel: *"Error de conexión, estamos trabajando para solucionarlo"*.
  La app queda funcionando visualmente (menús, transiciones) pero **sin datos**, como un banco
  real: no hay caché de saldos viejos.
- Al levantar de nuevo (`docker compose start db`), todo vuelve sin ningún paso extra porque
  no hay estados en el backend.

**Escenario de la demo:** se presenta **en sala con wifi, operada por el equipo** — se enseña
la app y de la vez **los cambios en la BD en vivo** (pgAdmin y/o la pestaña Control de §12).
El runbook (frente de Docker, §14) incluye: imágenes de Docker **precargadas** por si el wifi
falla, la semilla
creada **llamando a las funciones reales de la BD** (nunca SQL crudo: la demo también prueba
las funciones), y el flag de Resend listo para apagarse si el internet de la sala no acompaña.

## 11. Docker Compose (la infraestructura)

4 servicios en `docker-compose.yml`:

| Servicio | Imagen | Notas |
|---|---|---|
| `db` | `postgres:16-alpine` | PostgreSQL, volumen persistente, un **script de init SQL** (schema completo: tablas, funciones, triggers, vistas, semillas de productos y tasas). Healthcheck con `pg_isready`. |
| `pgadmin` | `dpage/pgadmin4` | Expuesto al host, para inspección. Conexión preconfigurable a `db:5432`. |
| `backend` | Node 20 alpino (build propio, `Dockerfile.backend`) | Express compilado. Depende del healthcheck de `db` para arrancar. Cadena de conexión vía variables de entorno. |
| `front` | Node para build + nginx alpino para servir (`Dockerfile.front`) | Sirve el build estático, con proxy de `/api` al backend (un solo origen: sin CORS). |

- Volumen **persistente** de la BD: si el profesor reinicia el contenedor (no borra el volumen),
  los datos siguen.
- Healthcheck de `db` con `pg_isready` y `depends_on: condition: service_healthy` — el backend
  no arranca antes de que la BD esté lista.
- Todo se levanta con `docker compose up -d` desde cero, siempre.

## 12. Front — mapa de pantallas

**Público:**
1. **Inicio** (landing informativa, estática): hero del banco, sección de **beneficios**,
   sección de **créditos** (los 4 productos, leyendo sus descripciones **de la BD** vía backend,
   pero con textos de marketing fijos si no hay datos — decisión de detalle), sección de
   **sistema de referidos** ("invita y gana $50.000"), footer. Botones "Registrarse" y "Ingresar".
   El logo/fotos de marketing son estáticos.
2. **Registro** (`/registro?ref=<uuid>`) — formulario con todos los campos de §7.1, validaciones
   en vivo (contraseña con reglas, teléfono, etc.), checkbox de política de datos, y el mensaje
   de éxito con el **username autogenerado** destacado (una sola vez).
3. **Login** (`/login`) — usuario + contraseña. Si la cuenta está bloqueada, el mensaje exacto
   de §7.2. Error genérico "Credenciales inválidas" si la combinación no sirve.

**Cliente (autenticado, con layout de panel y pestañas):**
1. **Inicio** (dashboard): saludo + balance total; últimas transacciones (envíos en ROJO con `-`,
   recibos en VERDE con `+`, con fecha y hora); tarjetas resumen de **CDTs** (cuántos activos,
   cuánto generado) y de **créditos** (cuánto queda por pagar, fechas, interés corriendo).
2. **Balance**: balance total desglozado (principal + bolsillos), lista de bolsillos con
   creación/edición/operación (meter, sacar, mover), y **historial de las últimas 50
   transacciones** con fecha y hora.
3. **Créditos**: lista de productos ofertados (desde la BD, con su tasa y sus límites) con el
   formulario/simulador (monto + plazo, y muestra **cuota mensual, total a pagar, intereses
   totales**) — al simular, botón "Solicitar este crédito" con las validaciones de §7.6
   (tope por balance, regla de edad en inmuebles); y la sección **"mis créditos"** con detalle
   por crédito: cuotas pagadas / faltantes, abono a capital en cualquier momento, y el estado
   del interés del mes.
4. **CDTs**: lista de definiciones (de la BD) con simulador (muestra lo generado al mes, al día
   y al vencimiento); creación directa desde lo simulado; sección "mis cdt" con cada cajita
   (monto, generado hasta hoy, **tiempo restante**), y la fecha de cierre.

**Admin (autenticado con rol ADMIN):**
1. **Usuarios** — lista + búsqueda + detalle + acciones (ver, bloquear, desbloquear, borrar).
2. **Operaciones** — añadir balance (usuario, monto, nota).
3. **Reloj** — toggle "usar fecha real" / fecha del sistema (solo adelante).
4. **Tasas** — editar tasas de CDT, tasas por producto de crédito y tasa de mora.
5. **Control** — el visor de la base de datos en vivo, estilo Supabase: **grafo de todas las
   tablas con sus relaciones** (FKs dibujadas como aristas entre tablas, badges por columna de
   llave/único/no-nulo), con búsqueda/filtro para enfocar una tabla, y clic en una tabla → sus
   filas paginadas. Todo con **ping periódico**: la pantalla se refresca sola mientras la
   pestaña está abierta. Es **solo lectura** y de paso es el **indicador de estado de la
   conexión**: si la BD cae, marca DESCONECTADO en rojo — puntazo directo para la demo del
   apagón. (El grafo: layout automático sobre las FKs reales leídas de `information_schema`.)

**Transversal:** el banner único de error de conexión (§10); confirmación de envío con nombre
del destinatario; el username y el código de referido en "Perfil"; y el nombre del banco es
**Banco Digital** (coherente con marketing del logo estático).

## 13. Backend — mapa de endpoints (esqueleto)

Sesión:
- `POST /api/auth/registro` → `SELECT registrar_usuario(...)`
- `POST /api/auth/login` → bcrypt + `SELECT login_usuario(...)` (trae rol/estado)
- `POST /api/auth/logout`
- `GET  /api/yo` → datos del usuario (perfil, código de referido, referido_por?)

Cliente (todas con sesión):
- `GET  /api/perfil` → datos, número de cuenta, código de referido
- `GET  /api/dashboard` → `SELECT * FROM vista_dashboard(cuenta)` (incluye el avance de reloj)
- `GET  /api/transacciones?limite=50` (o menos)
- `POST /api/envios` → `SELECT hacer_transferencia(...)`
- `GET/POST/PATCH /api/bolsillos` (+ `POST /api/bolsillos/:id/mover|retirar|ingresar`)
- `GET  /api/cdts/definiciones`, `GET /api/cdts`, `POST /api/cdts/simular`, `POST /api/cdts`
- `GET  /api/creditos/productos`, `GET /api/creditos/mis-creditos`,
  `POST /api/creditos/simular`, `POST /api/creditos`, `POST /api/creditos/:id/abono`

Admin (sesión + rol ADMIN):
- `GET   /api/admin/usuarios` (y búsqueda), `GET /api/admin/usuarios/:id`,
  `DELETE /api/admin/usuarios/:id`, `POST /api/admin/usuarios/:id/bloquear|desbloquear`
- `POST  /api/admin/balance`
- `GET/PUT /api/admin/reloj`
- `PUT /api/admin/tasas` (CDT, crédito, mora)
- `GET  /api/admin/esquema` → tablas, columnas y FKs (de `information_schema`; solo lectura;
  sirve también de ping)
- `GET  /api/admin/tabla/:nombre?pagina=N` → filas paginadas de una tabla (whitelist de
  tablas, solo lectura)

Regla global: cualquier error de BD → `503 {error:"sin_conexion"}` por **un solo middleware
de errores**. Los errores de negocio (saldo insuficiente, tope, cuenta bloqueada) vienen de la
BD como mensajes de texto de una función y el backend los pasa tal cual (con su `400`).

## 14. Equipo y reparto de trabajo

**Equipo (4):** Daniel García, Daniel Monterroza, Juan Marin y Jose Samur.

**Asignaciones: aún por definir.** Los frentes de trabajo ya están descritos con sus
entregables; el reparto de personas se decide aparte y se anota aquí cuando exista:

1. **Frontend** — proyecto React+Vite+TS; todas las pantallas de §12, cliente fetch con catch
   único, y la pestaña **Control** (grafo de relaciones en vivo).
2. **Backend** — proyecto Express+TS; middleware de sesión JWT (cookie httpOnly), bcrypt,
   rate limit de login, y el **middleware único de errores 503**; todos los endpoints de §13
   (cada uno llama a las funciones de la BD, no reinventa lógica); integración de Resend con
   su flag. *Depende del contrato de funciones, que se fija primero.*
3. **Docker / Infra** — el `docker-compose.yml` completo (4 servicios de §11), los
   `Dockerfile.backend` y `Dockerfile.front`, volumen persistente, healthchecks, el **script de
   init SQL** que levanta la BD desde cero (aplicando el schema del frente 4), y el **runbook
   de la demo** (cómo subir todo, cómo `stop db` y qué debe pasar). *Su entregable: que
   `docker compose up` funcione en una máquina limpia.*
4. **Base de datos** — el **corazón del proyecto**: schema completo (§5), todas las funciones
   de negocio (§7), triggers (bitácora automática, referidos, bloqueo de usuarios, validación
   de reloj), y **vistas** para el front (`vista_dashboard`, `vista_historial`, `vista_cdts`,
   `vista_creditos`). Prueba cada función desde pgAdmin antes de entregarla. *Cada función se
   revisa antes de merge — es lo evaluable del curso.*
5. **QA / Seed / Apagón** — seed de datos realistas (usuarios, bolsillos, CDTs, créditos
   "corridos" en el tiempo vía el reloj, siempre llamando funciones de la BD), pruebas
   funcionales de todos los flujos de §12 (registro→login→envío→CDT→crédito), y ensayar el
   apagón (§10) en local antes de la demo real.

**Git:** repo único con `main` protegida: una rama por pieza (`feat/db-core`, `feat/backend-auth`,
`feat/docker-compose`, `feat/front-*`); todos los merges los revisa Daniel.

**Nota:** sin calendario impuesto y sin asignaciones fijas de personas (§14 — los frentes
quedan descritos, el reparto se define aparte). Cuando exista la rúbrica del profesor se
revisa este documento contra ella y se ajusta antes de seguir.

## 15. Decisiones de diseño que tomé yo (revisar)

1. **Cobro lazy** (§8) en vez de un cron del backend: sobrevive al apagón y sirve la demo del
   reloj del admin. Si prefieren un cron, se convierte en un `SELECT avanzar_hasta(hoy)` que el
   backend llama al iniciar cada request — casi lo mismo.
2. **Tasa diaria = anual / 365** para bolsillos y CDTs, e **i mensual = anual/12** para créditos;
   la rentabilidad se calcula por días corridos, no por días hábiles.
3. **Amortización francesa** (cuota fija) en créditos, y abonos a capital que **recalculan la
   cuota** manteniendo plazo y tasa (no acortando meses).
4. **CDTs no acumulan interés por día en el balance**: el interés queda en el propio CDT
   (`generado_acumulado`) y se libera **todo al vencer**. Así el balance principal no se mueve
   cada día y el "generado" es visible por cajita.
5. **Borrado de usuario con cascada total** (sus productos, bolsillos, CDTs, créditos y
   transacciones se van con él) — para el alcance universitario es lo limpio.
6. **Login solo por username** (el autogenerado), no por correo — el username es la identidad
   del banco.
7. Nombre del banco: **Banco Digital** (trabajo académico independiente, sin relación con
   marcas externas; el equipo lo renombra luego si quiere — solo toca logo/textos).
8. **Errores de negocio vs conexión (regla mecánica)**: los errores de negocio de la BD se
   lanzan con `SQLSTATE 'P0001'` (`RAISE EXCEPTION`) → el backend responde `400` con el mensaje
   de la función tal cual; **todo lo demás** (conexión rechazada, timeouts) → `503
   sin_conexion`. Una sola línea de distinción, sin ambigüedad entre capas.
9. **Concurrencia**: las funciones que tocan dinero (transferencia, cobro lazy, cuotas, abonos)
   bloquean la fila de la cuenta dentro de su transacción (`SELECT ... FOR UPDATE`) — un doble
   click o dos peticiones simultáneas no pueden cobrar dos veces. Material evaluable de paso.
10. **Volver a fecha real tras adelantar el reloj**: permitido y sin corromper nada — el
    `ultimo_cobro` de cada producto impide recargar intereses ya cobrados; los días ya
    recorridos no se regeneran. El reloj del banco no retrocede dentro del modo manual — la
    meta es adelantar para PROBAR, no para dejar la fecha quedada ahí.
11. **Contraparte como texto en historiales**: al borrar un usuario con cascada, sus
    transacciones mueren con él, pero en el historial de terceros queda el `nombre + número de
    cuenta` guardados como texto — sin FKs huérfanas.
12. **Mora editable**: la `tasa_mora_anual` vive en `parametro` y se edita desde la pestaña
    Tasas del admin.

## 16. Orden técnico del trabajo (sin calendario ni asignaciones)

1. **Contratos primero:** fijar firma exacta de las funciones de la BD (nombre, argumentos,
   retorna) y de los endpoints de §13 — con eso los frentes trabajan en paralelo sin chocar.
2. En paralelo: el frente de **BD** con schema + funciones core, **Docker** con el Compose y
   los Dockerfiles, **Backend** con el esqueleto + sesión, y el **front** avanzando con datos
   de mentira (con la misma forma que los endpoints darán).
3. **Integración por etapas:** primero auth + dashboard (vistas), luego envíos + bolsillos,
   luego CDTs, luego créditos, por último admin + reloj + tasas + Control.
4. **QA de cierre:** recorridos completos + la demo del apagón ensayada.

---

*Este documento es la única fuente de verdad hasta el final. Cualquier cambio se agrega aquí
con fecha — después se planea el trabajo con un plan de implementación.*
