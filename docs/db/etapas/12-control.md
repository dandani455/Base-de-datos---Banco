# Etapa 12 — Control (visor de la base de datos: `admin_esquema` y `admin_tabla`) · paquete de entrega

**Estado (2026-11-25): IMPLEMENTADA; auditoría con UN caso límite corregido (§8); PENDIENTE DE TU APROBACIÓN FINAL.** Diseño v1 aprobado (`12-control-diseno.md`; D-E12-1 a D-E12-6) y seguido sin cambiar el alcance. **D-E12-D1 (solo `password_hash` se enmascara) y D-E12-D2 (`audit.evento` fuera del visor) siguen siendo valores provisionales del equipo**, centralizados en `_reglas_control()`. Sin commits; `front/` y backend intactos (el backend de `origin/main` es un borrador temporal y no se usó como autoridad); **E13 no iniciada.**

## 1. Qué se entrega

| Pieza | Archivo |
|---|---|
| 2 públicas `admin_esquema(admin)` y `admin_tabla(admin, tabla, pagina text)` + interna `_reglas_control()` | `db/sql/25_control.sql` (idempotente, transaccional, comentado; **no modifica ningún objeto de E1–E11**; sin tablas, triggers ni auditoría nuevos) |
| Integración (solo inventarios y permisos) | `09_integridad.sql` (lista blanca de `banco_app` 38 → **40**, su texto y el comentario de `v_integridad_defensas`), pruebas adaptadas (§3) |
| Pruebas nuevas | `71_control` (40, tras §8) y `reales/55_control_conexiones` (24) = **64** |
| Mutaciones | `db/tests/mutaciones/mutaciones.sh`: **M401–M433** (33) |
| Resumen para el backend | `12-resumen-para-juan.md` |
| Evidencias | `docs/db/evidencias/12-control*.txt`, `12-pgadmin-demo.sql` y su salida, `git_status_e12.txt` |

## 2. Cómo funciona

```
admin_esquema(admin) / admin_tabla(admin, tabla, pagina)
 _validar_admin (E4)  ← lo PRIMERO (un cliente no puede ni sondear qué tablas existen)
 → admin_esquema: pg_catalog de las 11 tablas de la lista → {tablas:[{nombre, columnas[], fks[]}]}
 → admin_tabla  : lista blanca EXACTA → nombre TOMADO DE LA LISTA (%I) → cuenta + página (recorte) → filas SIN el hash + «••••»
```

* **Solo lectura por catálogo:** ambas `STABLE` (PostgreSQL impide que escriban); sin motor de devengo ni auditoría (el visor muestra **lo guardado**, no lo derivado).
* **Esquema:** una fila por tabla de la lista (orden del grafo); `tipo` = `format_type` literal; `llave` = clave primaria; `unico` = `UNIQUE` de **una** columna; `no_nulo`; FK **una por restricción** con su primera columna (la compuesta `cuenta` → `usuario` sale una vez). Es también el ping de conexión: solo `pg_catalog`.
* **Tabla:** 50 por página, `total_paginas = max(1, ceil(n/50))`; `pagina` es **texto** (inválido o `< 1` = 1, mayor al total = la última); orden: lo más reciente primero donde hay marca de tiempo u orden; filas = todas las columnas, dinero como número, fechas ISO `-05:00`, `tx_id` (`xid8`) como texto. Fuera de la lista (comparación exacta; incluye `audit.evento`, otros esquemas, `NULL` e inyecciones) = **`Tabla no permitida`**.
* **El hash nunca entra al JSON:** `usuario.password_hash` sale siempre como `••••`.

## 3. Resultados

| Verificación | Resultado |
|---|---|
| Suite completa (`ctl.sh test --evidence 12-control`) | **3098 aprobadas, 0 fallidas** (E11 cerró en 3036: **+62**, 0 menos; las adaptadas siguen verdes). Tras la corrección de §8 la suite tiene **2 aserciones más** (3100); **no se repitió la suite completa** (solo `71` y `55`, §8). El estimado del diseño era ≈ +75. |
| Pruebas nuevas | `71_control` **38 → 40**, `reales/55_control_conexiones` **24** |
| `reset` + 3 × `apply` desde cero | **sin errores** (`12-control-aplicacion.txt`; **26 archivos** por pasada): 11 tablas + `audit.evento`, **128 funciones**, **21 triggers** (ninguno nuevo), **9 vistas**; `banco_app` ejecuta exactamente **40** (14 `admin_*` y ninguna interna); `v_integridad_global.ok`, 0 defensas fallidas; `banco` queda **limpia** (0 usuarios, reloj real, mora NULL, sin esquema `tests`) |
| Mutaciones nuevas M401–M433 (33) | **32 detectadas + 1 equivalente declarada (M407)** (`12-control-mutaciones.txt` y, para M431–M433, `12-control-correccion-pagina-mutaciones.txt`) |
| Regresión (E2–E11: libro, auditoría, reloj, integridad, motor, `vista_cdts`, permisos, plantillas y de E11 acceso/ajuste/permisos; 64) | **64 de 64** (`12-control-mutaciones-regresion.txt`) |
| Demo de pgAdmin | `12-pgadmin-demo.sql` + salida real `12-pgadmin-demo-salida.txt` (todo en `BEGIN … ROLLBACK`; `banco` queda limpia) |

Qué cubre cada archivo nuevo:
* **71** — **esquema** contra un **oráculo independiente de `information_schema`** (nombre, orden, llave, unico, no_nulo y tipo de **todas** las columnas, más de 100; las 12 FK una a una; `referido_por → id`; la compuesta una sola vez); la **lista blanca = las tablas base reales de `public`** (si alguien agrega una tabla, falla); **tabla**: forma de `types.ts`, 50 por página, recorte de página (`NULL`, vacío, espacios, `abc`, 0, −3, `1.5`, `1; DROP TABLE usuario`, 11 dígitos, 99, 999999999), tabla vacía, las 11 tablas (columnas = las del esquema y claves de cada fila = esas columnas), orden (`creado_en DESC, id`, `orden DESC`, cuota), **hash**: `••••` exacto en las 3 páginas y el hash real **de nadie** aparece en ninguna de las 11 tablas, sin sobre-enmascarar (la fila de `cuenta` es exactamente `to_jsonb`), tipos JSON y fechas `-05:00` con la sesión en UTC; **lista blanca** con 12 nombres inválidos, `NULL` e inyecciones; el administrador se valida **antes** que la tabla; **solo lectura** (STABLE, sin `INSERT/UPDATE/DELETE` en el código, huella y auditoría intactas, y con el reloj +40 días **no devenga**); valores provisionales fijados; catálogo y permisos.
* **reales/55** (roles reales por TCP, sin superusuario) — la conversación del front con las 11 tablas, el hash **real de la BD** no viaja, `Tabla no permitida` con `P0001`, la página como texto del query-string; cliente real / admin bloqueado / uuid desconocido sin acceso; `banco_lector` y el helper sin `EXECUTE`; **100 pings seguidos en < 5 s**; el visor responde **sin esperar** mientras otra sesión mantiene tomados el reloj y una cuenta; **concurrencia** (6 pings + 6 lecturas de `transaccion` durante 60 transferencias: sin errores y el libro cuadra).

**Pruebas anteriores adaptadas (solo inventarios y permisos; ninguna se eliminó):** `03_schema` (128 funciones), `10_libro_triggers` (SECURITY DEFINER +2, lista blanca 40, 127 de `banco_owner`), `09_idempotencia` (reaplica `25`), `52`, `55`, `65`, `reales/45`, `47`, `49` (lista blanca 40), `54` (catálogo: **19 devengan, 21 exentas**), y las de E11 que cuentan `admin_*`: `69` (tabla de control de acceso +2, G7 y G8: 12 → 14; G7 ahora dice «ninguna **de E11** usa SQL dinámico»: el único dinámico es `admin_tabla`, con lista blanca y `%I`) y `reales/53` (B1: 14).

## 4. Decisiones aprobadas y cómo se reflejan

| ID | Cómo quedó |
|---|---|
| D-E12-1 | 2 públicas + `_reglas_control()` + `25_control.sql`; sin triggers, tablas ni auditoría; sin motor. |
| D-E12-2 | Lista explícita de 11 nombres (orden = grafo); prueba de deriva contra `public`; comparación exacta; SQL dinámico solo con el nombre de la lista y `%I`. |
| D-E12-3 | Esquema desde `pg_catalog`; `tipo` literal; `unico` de una columna; FK compuesta = 1 entrada con su primera columna; `STABLE`. |
| D-E12-4 | Ni motor ni auditoría: el visor muestra lo guardado (probado con el reloj +40 días). |
| D-E12-5 | `p_pagina text` con recorte; 50 por página; `max(1, ceil(n/50))`; orden más reciente primero y desempate por `id`. |
| D-E12-6 | Todas las columnas; números como números; `tx_id` como texto; `password_hash` siempre `••••`. |
| **D-E12-D1 (equipo)** | **Provisional:** solo se enmascara `password_hash`; cédula, correo y teléfono salen. Un valor de `_reglas_control()` (fijado por `71`/C4). |
| **D-E12-D2 (equipo)** | **Provisional:** `audit.evento` no está en el visor. |
| D10 | `pagina` como texto (firma no literal del contrato), provisional. |

## 5. Desviaciones y límites (sin ocultar nada)

1. **Menos aserciones que el estimado:** +62 (≈ +75). `71` tiene 38 (≈ 55) porque las comparaciones con el oráculo de `information_schema` son **por conjuntos** (una aserción cubre las columnas y las FK de las 11 tablas), no una por columna; `reales/55` tiene 24 (≈ 20).
2. **Mensaje en `_reglas_control()`** y no en `_msg_negocio` (E5 no se modifica; igual que E6 y E11). Es el mensaje exacto del contrato §6.
3. **`admin_tabla` es la única función `admin_*` con SQL dinámico** (`EXECUTE`): protegida por la lista blanca exacta, el nombre tomado de la lista y `%I` (probado con 18 nombres inválidos o inyecciones, y por la mutación M417). `G7` de E11 se ajustó para decirlo.
4. **Pruebas de tiempo** (`reales/55`: 100 pings en < 5 s; < 2 s con el reloj y una cuenta tomados): son cotas amplias para una máquina normal; en un equipo muy cargado podrían ser sensibles.
5. **Demo:** el control de autenticación de `v_integridad_global.ok` no aplica porque los 70 usuarios de relleno se insertan sin cuenta ni ingresos; la demo imprime los controles del libro y de las defensas.
6. **M407 es equivalente:** quitar la resta de las columnas enmascaradas antes de `||` no cambia lo observable (el `||` reemplaza el valor); la resta es una defensa redundante.
7. **Límites de diseño (documentados):** el visor muestra lo **guardado**, no el interés pendiente; `count(*)` por llamada (despreciable a esta escala); un admin ve datos personales de todos (D-E12-D1); `tx_id` y otras columnas técnicas se muestran tal cual (decisión visual del front).
8. **Front:** su mock aún pagina de 10 y responde `Tabla no encontrada` (el contrato dice 50 y `Tabla no permitida`); se avisa en el resumen para el backend, no se tocó.

## 6. Mutaciones

Bloque **M401–M430** (30): control de acceso (`_validar_admin` ausente en cada una y validación tardía), **hash** (sin máscara, máscara en otra columna, máscara distinta), paginación y orden (49 por página, sin recorte, `floor`, página 0, orden invertido), **lista blanca** (con `audit.evento`, sin distinguir mayúsculas, mensaje, `%s` en vez de `%I`), esquema (FK compuesta duplicada, FK propia ausente, `llave`/`unico`/`no_nulo`/`tipo` mal, orden alfabético) y solo lectura/permisos (2 `VOLATILE`, `SECURITY INVOKER`, 3 `GRANT`).

**Resultado: 29 detectadas + 1 equivalente (M407)**, a la primera, sin huecos. **Regresión: 64 de 64** (las 55 de E11 más M341, M354, M376 y M395–M400).

## 7. Verifícalo en pgAdmin

1. Conexión **«Banco — administración (postgres)»** → base `banco` → Query Tool → *Open File* → [12-pgadmin-demo.sql](../evidencias/12-pgadmin-demo.sql) → **F5** (todo en `BEGIN … ROLLBACK`; los resultados salen como `NOTICE`). Salida de referencia: [12-pgadmin-demo-salida.txt](../evidencias/12-pgadmin-demo-salida.txt).
2. Consultas sueltas (superusuario; no escriben; sustituye el uuid de un administrador):
   * `SELECT public.admin_esquema('<uuid admin>');` — el grafo en JSON.
   * `SELECT public.admin_tabla('<uuid admin>', 'usuario', '1');` — filas con `password_hash` = `••••`.
   * `SELECT public._reglas_control();` — lista blanca, orden, máscara y mensaje en un solo lugar.
   * `SELECT proname, provolatile FROM pg_proc WHERE proname IN ('admin_esquema', 'admin_tabla');` — `s` = `STABLE` (solo lectura).

## 8. Corrección de la auditoría: `p_pagina` de más de 9 dígitos (2026-11-25)

**Defecto:** `admin_tabla` solo reconocía números de hasta 9 dígitos (`^[0-9]{1,9}$`): `1000000000` (entero válido, mayor que cualquier total) caía en la rama «no numérico» y devolvía la **página 1** en vez de la **última**. Un entero de 10 o más cifras debe limitarse a la última página, sin desbordar.

**Corrección (`25_control.sql`, solo la conversión de `p_pagina`):** si el texto son solo dígitos (cualquier longitud) se quitan los ceros a la izquierda; sin cifras = página 1; **más de 18 cifras** (no caben en un `bigint`) = **la última, sin convertir** (no hay desbordamiento posible); si no, `greatest(1, least(n::bigint, total))`. **Se conserva:** `NULL`, vacío, espacios, negativos, signos, decimales, notación científica y texto = página 1; «0», solo ceros = 1; páginas válidas con ceros a la izquierda (`0000000000002` = 2).

**Pruebas:** en `71` se quitó el caso `12345678901` de la lista de «página 1» (era el propio defecto), y se añadieron **B5b** (11 valores: `1000000000`, `2147483647/8`, `4294967296`, `9223372036854775807/8`, 20 cifras, 30 cifras, **5000 cifras**, con ceros a la izquierda y con espacios: todos = la última página y **nunca un error**) y **B5c** (11 valores que conservan el comportamiento: ceros a la izquierda de una página válida, solo ceros, `NULL`, vacío, negativo, `+5`, `1e9`, decimal, coma, texto y 5000 letras). **Mutaciones nuevas M431–M433** (más de 9 dígitos vuelve a 1; sin la guarda de longitud desborda; más de 18 dígitos da 1) y la regresión **estrictamente necesaria**: M408–M411 (paginación) → **7 de 7 detectadas** (`12-control-correccion-pagina-mutaciones.txt`; M409 y M411 se reescribieron porque su patrón cambió). Corridas: `71` **40 aprobadas, 0 fallidas** (`12-control-correccion-pagina.txt`) y las de prefijo `55` (incluye `reales/55`) **89 aprobadas, 0 fallidas** (`12-control-correccion-reales55.txt`). `25_control.sql` se reaplicó a `banco` (idempotente). **No se repitió** la suite completa ni la regresión de las 64 (nada más cambió).