# Etapa 12 — Control (visor de la base de datos: `admin_esquema` y `admin_tabla`) · DISEÑO TÉCNICO v1 (compacto, para aprobación)

**Estado (2026-11-25): DISEÑO v1 APROBADO (D-E12-1 a D-E12-6) e IMPLEMENTADO (ver `12-control.md`, pendiente de auditoría).** E11 está aprobada y cerrada. No se ha tocado `db/sql`, pruebas, `front/` ni backend; sin commits; E13 no iniciada. **El backend de `origin/main` es un borrador temporal y no se usó como fuente de autoridad:** solo se miró para no contradecir nombres ya acordados (`admin_esquema`, `admin_tabla`), y cada decisión sale del contrato, de `types.ts`, del front y de la BD.

**Fuentes consultadas:** contrato PDF 2026-11-18 (§3.6 `GET /admin/esquema` y `/tabla`, §6 mensajes, §8 checklist), `front/src/api/types.ts` (`Esquema`, `EsquemaTabla`, `EsquemaColumna`, `EsquemaFk`, `PaginaTabla`), `front/src/pages/admin/Control.tsx` y `admin.test.tsx`, `front/src/components/Grafo.tsx`, `front/mock/server.mjs` (esquema, `filasTabla`, `/admin/tabla`), spec §12 (pestaña Control) y §13 (endpoints), el plan (Task 8: «FIX 8») y el diseño consolidado v3 (§C.8, §E.1), y la BD real (catálogo: 11 tablas de `public`, 12 FK, 12 `UNIQUE`, tipos de columna, serialización JSON de `xid8`/`timestamptz`). **Reutiliza:** `_validar_admin` (E4), el patrón `_reglas_*` de valores centralizados (E5–E11), `SET TimeZone` por código (D-E10-8) y las adaptaciones de inventario de cada etapa.

## 1. Alcance

| Entra en E12 | No entra |
|---|---|
| **2 públicas** `admin_esquema(p_admin_id)` y `admin_tabla(p_admin_id, p_tabla, p_pagina)` + **1 interna** `_reglas_control()` (lista blanca, orden, columnas enmascaradas, tamaño de página, mensaje) · script `db/sql/25_control.sql` · sin tablas, sin triggers, sin eventos de auditoría | Mantenimiento (`sp_*`, E13); seed (E14); mostrar `audit.evento` en Control (D9b, §6); cualquier cambio de `front/` o backend |

## 2. Qué dicen las fuentes y qué hallé (contrato manda; `types.ts` manda sobre el PDF)

| Tema | Fuentes | Resolución |
|---|---|---|
| **Forma de `admin_esquema`** | Contrato: `{tablas:[{nombre, columnas:[{nombre, tipo, llave, unico, no_nulo}], fks:[{columna, tabla_destino, columna_destino}]}]}`, «salido de `information_schema`/`pg_catalog`», **solo las 11 tablas**, incluye `usuario.referido_por → usuario.id`. `types.ts`: `tipo`, `llave`, `unico`, `no_nulo` y `columna_destino` **opcionales**. `Grafo.tsx`: dibuja un nodo por tabla y **una arista por cada entrada de `fks`**; muestra badges `PK / UQ / NN`. | `jsonb` con exactamente esa forma; `llave` = columna de la clave primaria, `unico` = columna con una restricción `UNIQUE` **de una sola columna** (la PK no se repite como único), `no_nulo` = `NOT NULL`. |
| **Es el «ping» de conexión** | Contrato: «debe ser barato (el front lo llama cada 5 s)»; `Control.tsx`: ping con guarda y refresco de la tabla elegida en cada ping | Función `STABLE` de solo lectura sobre `pg_catalog` (11 tablas), sin motor de devengo y sin escribir nada. El backend la llamará 12 veces por minuto por pestaña abierta. |
| **Forma de `admin_tabla`** | Contrato: `{columnas: string[], filas: object[], pagina (desde 1), total_paginas}`, **50 filas por página**, solo lectura, lista blanca de las 11 tablas, **`Tabla no permitida`** fuera de ella (§6, mensaje exacto), `usuario.password_hash` enmascarado como **`••••`** y «nunca debe viajar el hash real» (§8). | Una sola función, una sola sentencia (foto consistente de filas y conteo). El mock usa 10 por página y `Tabla no encontrada`: **obsoletos**, gana el contrato. |
| **Composite FK** | Hay **una** FK compuesta: `cuenta (usuario_id, rol) → usuario (id, rol)` (subtipo CLIENTE de E1). El contrato solo conoce FK de una columna y `Grafo` dibujaría una arista por entrada. | Una entrada **por restricción**, con su **primera columna** (`cuenta.usuario_id → usuario.id`); evita una arista duplicada `rol → rol`. Todas las demás FK (11) son de una columna. |
| **Qué columnas salen** | El contrato no dice. `Control.tsx` pinta `String(fila[c] ?? '')` para cada `columnas[c]` (no hay columnas `jsonb` en las 11 tablas). Hay columnas técnicas (`transaccion.tx_id` es `xid8` y **`to_jsonb` lo serializa como texto**: `"2035665"`; `lado` es generada). | **Todas** las columnas de la tabla (es un visor de la BD real), en el orden del catálogo; `columnas` de `admin_tabla` = las de `admin_esquema` para esa tabla. Los `numeric` salen como **número**, fechas ISO (zona de Bogotá por código), uuid como texto; `tx_id` queda como texto (no es un `numeric`; el front lo imprime igual). |
| **Datos mostrados = datos guardados** | Spec §12: «estado en vivo de la BD». El motor es perezoso (E7–E9): los saldos de `cuenta`/`bolsillo` no incluyen el interés pendiente hasta que alguien operaba o miraba. | El visor muestra **lo guardado**, no lo derivado: **no corre el motor** (correrlo escribiría en cada ping de 5 s y el visor ya no sería «solo lectura»). Límite que se documenta. |
| **Qué es `p_pagina`** | Contrato: `p_pagina` entero; el front manda `?pagina=N`. | Parámetro **`text`** (D10, mismo criterio que E11 con ids y tasas): `NULL`, vacío, no numérico o `< 1` = 1; mayor que el total (de cualquier longitud) = **la última página** (como el mock; la respuesta trae la página efectiva). Así ningún valor del query-string produce un error de driver. |
| **Lista blanca** | Contrato/plan: «de las 11 tablas». | Lista **explícita** de 11 nombres en `_reglas_control()` (en el orden de §5 / del mock, que también es el orden del grafo). Un test compara esa lista con las tablas base reales de `public`: si alguien agrega una tabla, **falla** hasta que se decida. `audit.evento` y el esquema `tests` quedan fuera. |
| **Nombre de tabla inválido** | §6: `Tabla no permitida`. | Comparación **exacta** con la lista (sin `lower()`, sin esquema, sin comillas): `usuario` sí; `Usuario`, `public.usuario`, `audit.evento`, `pg_user`, `usuario; DROP …`, `''`, `NULL` = `Tabla no permitida`. El SQL dinámico solo usa el nombre **tomado de la lista** con `format('%I')`, nunca el texto recibido. |

## 3. Diseño

**Orden de ambas:** `_validar_admin(p_admin_id)` primero (`Acceso denegado` / mensaje de bloqueo; se relee el estado en cada ping) → validar parámetros → una sola sentencia → `jsonb`. `SECURITY DEFINER`, `search_path = public, pg_temp`, `SET TimeZone = 'America/Bogota'`, **`STABLE`** (PostgreSQL impide que una función `STABLE` escriba: la garantía «solo lectura» queda en el catálogo, no solo en el código).

| Firma | Salida | Detalle |
|---|---|---|
| `admin_esquema(p_admin_id uuid)` | `{tablas: [{nombre, columnas: [{nombre, tipo, llave, unico, no_nulo}], fks: [{columna, tabla_destino, columna_destino}]}]}` | Solo las 11 tablas, en el orden de la lista blanca; columnas por `attnum`; `tipo` = `format_type` tal cual (`dinero`, `uuid`, `timestamp with time zone`, `estado_usuario`…: los dominios y enumeraciones de E1 se conservan, es información útil); FK solo entre tablas de la lista; `[]` si la tabla no tiene FK. |
| `admin_tabla(p_admin_id uuid, p_tabla text, p_pagina text DEFAULT NULL)` | `{columnas: [..], filas: [{..}], pagina, total_paginas}` | 50 filas por página; `total_paginas = max(1, ceil(count/50))` (tabla vacía: `filas: []`, página 1 de 1); orden estable por tabla (§4 D-E12-5); cada fila es la fila real en JSON **sin** las columnas enmascaradas, que se agregan con `••••`. |
| `_reglas_control()` (interna, `IMMUTABLE`) | `{tablas: [...11...], pagina_tam: 50, orden: {tabla: expresión}, enmascarar: {usuario: [password_hash]}, enmascara: '••••', msg_tabla: 'Tabla no permitida'}` | **Un solo lugar** para todo lo provisional. El mensaje es contractual (§6) pero vive aquí y no en `_msg_negocio` (E5 no se modifica; mismo criterio que E6 y E11). |

**Máscara.** El hash **nunca entra** al JSON de salida: la fila se arma como «fila menos `password_hash`» más `password_hash = '••••'` (siempre, también si fuera nulo). La prueba inserta un hash reconocible y exige que ese texto no aparezca **en ninguna parte** de la respuesta de las 11 tablas.

**Permisos.** `EXECUTE` de las 2 públicas solo para `banco_app` (`banco_dev` hereda); `_reglas_control` para nadie. El dueño ya puede leer las 11 tablas (no hace falta ningún `GRANT` nuevo). Esperado: **125 → 128 funciones**, lista blanca de `banco_app` **38 → 40**, `SECURITY DEFINER` +2, **21 triggers (ninguno nuevo)**, 9 vistas, 11 tablas + `audit.evento`.

## 4. Integración con etapas anteriores y concurrencia

* **Motor (E7–E9):** las dos son **exentas** (catálogo de `54`: 19 devengan, **21 exentas**): no leen saldos derivados ni llaman al motor. **Auditoría:** ninguna (solo lectura, 12/min; no es una acción administrativa).
* **Concurrencia:** lecturas `STABLE` sin bloqueos de fila ni locks: no estorban a las transferencias ni a los borrados y no esperan el reloj. Una paginación bajo escritura concurrente es una foto consistente por llamada (puede variar entre llamadas: es un visor «en vivo»).
* **Costo:** el `count(*)` se hace por llamada y el front refresca la tabla elegida cada 5 s: a la escala del proyecto (≈ decenas de miles de filas) es despreciable; si `transaccion` creciera mucho, la alternativa es un conteo estimado (no se propone ahora).
* **Adaptaciones de inventario (solo números y listas, como en cada etapa; ninguna prueba se elimina):** `03_schema` (128), `10_libro_triggers` (SECURITY DEFINER +2, 127 de `banco_owner`, lista blanca 40), `09_integridad.sql` (lista blanca y su texto: **40**, «E4-E12»), `09_idempotencia` (reaplica `25`), `52/55/65` y `reales/45/47/49` (lista blanca 40), `54` (+2 exentas), y las de E11 que cuentan `admin_*`: `69` (G1/G7/G8: 12 → **14** y las 2 nuevas en la tabla de control de acceso) y `reales/53` (B1: 12 → 14). `67` (A9) ya excluye `admin_%`.

## 5. Decisiones

**Técnicas (las aprueba el responsable de BD):**

| ID | Decisión | Recomendación |
|---|---|---|
| **D-E12-1** | Alcance: 2 públicas + `_reglas_control()` + `25_control.sql`; sin triggers ni tablas; sin auditoría; sin motor. | Aprobar. |
| **D-E12-2** | Lista blanca **explícita** de 11 nombres (orden = orden del grafo) + test de deriva contra `public`; comparación exacta; SQL dinámico solo con el nombre de la lista y `%I`. | Aprobar. |
| **D-E12-3** | `admin_esquema` desde `pg_catalog`: `tipo` = `format_type` literal; `unico` = UNIQUE de **una** columna; FK compuesta = una entrada con la primera columna; solo las 11 tablas; `STABLE`. | Aprobar (alternativa: resolver dominios al tipo base — descartada: pierde información de diseño y el front no muestra `tipo`). |
| **D-E12-4** | **No corre el motor y no audita**: el visor muestra lo guardado; ambas `STABLE` (solo lectura garantizada por el catálogo). | Aprobar. |
| **D-E12-5** | `admin_tabla`: `p_pagina text` (D10; inválido/`<1` → 1, mayor al total → última), 50 por página, `max(1, ceil(n/50))`, orden estable: **más reciente primero** donde hay marca de tiempo u orden (`transaccion` por `orden DESC`; `usuario`, `cuenta`, `bolsillo` por `creado_en DESC`; `cdt` por `fecha_inicio DESC`; `credito` por `fecha_desembolso DESC`), `cuota` por `(credito_id, numero)` y las pequeñas (`cdt_definicion`, `credito_producto`, `reloj`, `parametro`) por nombre/id; desempate por `id`. | Aprobar (el orden es visual y vive en `_reglas_control()`; cambiarlo es editar un valor). |
| **D-E12-6** | Todas las columnas de cada tabla, números como números, `tx_id` (xid8) como texto, `password_hash` siempre `••••`. | Aprobar. |

**Pendientes del equipo / front (no se decide aquí; hay un valor provisional centralizado):**

| ID | Cuestión | Estado en E12 |
|---|---|---|
| **D-E12-D1** | ¿Enmascarar también otros datos personales (`cedula`, `correo`, `telefono`, `fecha_nacimiento`)? El plan habla de «columnas sensibles enmascaradas» (FIX 8) pero el contrato solo nombra `password_hash`; el admin ya ve cédula y correo en la lista de usuarios. | **Solo `password_hash`** (contrato). Cambiarlo = una línea de `_reglas_control()`. |
| **D-E12-D2** | **D9b:** ¿mostrar `audit.evento` en Control? Hoy el contrato exige solo las 11 tablas. | Fuera (se agregaría como una 12.ª entrada de la lista, con su propia decisión de qué ocultar). |
| **D10** | Firma no literal del contrato: `p_pagina` como texto. | Provisional; Juan/backend lo confirman cuando haya backend definitivo. |
| Front (obsoletos) | El mock pagina de 10 y responde `Tabla no encontrada`; el contrato dice 50 y `Tabla no permitida`. | Gana el contrato; el front alinea su mock. |

## 6. Ambigüedades del contrato detectadas

(a) `tipo` sin formato definido (el front no lo muestra); (b) página fuera de rango sin comportamiento definido (se elige «última»); (c) FK compuesta no contemplada; (d) si `unico` incluye la PK; (e) «las 11 tablas de §5» remite a una sección que en el PDF es el seed, no la lista (se fijó con el catálogo real: 11 tablas de `public`); (f) no dice si el visor debe reflejar el devengo pendiente; (g) `tx_id` no es `numeric` pero sale como texto.

## 7. Plan de pruebas (solo riesgos nuevos; no se repiten E1–E11)

| Archivo | Riesgo que cubre | Aserciones ≈ |
|---|---|---|
| `71_control.test.sql` | **Esquema:** forma de `types.ts`; exactamente las 11 tablas en el orden de la lista y = tablas base de `public` (deriva); `llave`/`unico`/`no_nulo`/`tipo` de **todas** las columnas contra un **oráculo independiente** (`information_schema`); FK: las 12 de catálogo → 12 entradas, incluida `usuario.referido_por → usuario.id` y la compuesta como una sola; ni `audit` ni `tests`. **Tabla:** forma; 11 tablas devuelven sus columnas del catálogo y claves de fila ⊆ columnas; 50 por página (≈ 120 usuarios → 3 páginas, la última de 20), recorte de página (`NULL`, `''`, `'abc'`, 0, −3, 99), tabla vacía, orden y desempate; **máscara** (hash real inexistente en toda la salida de las 11 tablas; `••••` exacto; las demás columnas intactas); tipos JSON (números, fechas `-05:00` con la sesión en UTC); **lista blanca** (los inválidos de §2 y que no haya efectos); **solo lectura** (`provolatile = 's'` en ambas, sin `INSERT/UPDATE/DELETE` en su código, sin cambios de huella ni de auditoría); control de acceso de las 2 (cliente, desconocido, NULL, admin bloqueado); catálogo (`_validar_admin` primero, sin motor, sin reloj suelto, `%I`, permisos). | ≈ 55 |
| `reales/55_control_conexiones.sh` | Roles reales por TCP: la conversación del contrato (esquema y las 11 tablas, el hash real de la BD no viaja), cliente real = `Acceso denegado`, `banco_lector` sin `EXECUTE`, **ping «barato»** (100 llamadas seguidas bajo un tope de tiempo) y **concurrencia** (20 pings + 20 lecturas de `transaccion` mientras 4 sesiones transfieren: sin errores, sin esperas y el libro cuadra). | ≈ 20 |

**Estimado: ≈ +75 aserciones; ≈ 24 mutaciones (M401…)**: sin `_validar_admin` (2), lista blanca ignorada o ampliada (`audit.evento`), nombre sin `%I`, máscara ausente / en otra columna / hash en claro, 49 o 51 por página, sin recorte de página, `total_paginas` por defecto, orden invertido, FK `referido_por` ausente o compuesta duplicada, banderas `llave`/`unico`/`no_nulo` mal, tabla fuera de la lista en el esquema, `VOLATILE`, `SECURITY INVOKER` y permisos (`PUBLIC`, `banco_lector`, helper). Regresión: las mutaciones de permisos/lista blanca de E5–E11 que cambian por el inventario.

## 8. Riesgos y límites

1. El visor muestra datos **guardados** (no incluye el interés pendiente de bolsillos/CDT/créditos hasta que alguien opere): es lo que se ve «en la BD real».
2. Un admin ve los datos personales de todos los usuarios (cédula, correo, teléfono) en `usuario`: igual que en la lista de E11; D-E12-D1 lo deja a decisión del equipo.
3. Cada ping consulta el catálogo y valida al admin: costo mínimo, pero depende de que el backend no lo llame más de lo previsto (5 s).
4. Si se agrega una tabla a `public` sin decidir su visibilidad, la prueba de deriva falla a propósito.
5. `tx_id` y otras columnas técnicas se muestran tal cual (puede confundir en la demo); ocultarlas sería una decisión visual del front.
