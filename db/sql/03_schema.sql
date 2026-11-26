-- ============================================================================
-- 03_schema.sql  ·  Etapa 1 (esquema y permisos)
-- Propósito  : las 11 tablas del negocio en el esquema public y la bitácora audit.evento en el
--              esquema audit, con todas sus restricciones y su documentación (COMMENT ON).
--
--   public: usuario, cuenta, bolsillo, cdt_definicion, cdt, credito_producto, credito, cuota,
--           transaccion, reloj, parametro                          (exactamente 11 tablas)
--   audit : evento                                                 (sin ninguna FK)
--
-- Alcance    : SOLO estructura y restricciones de CADA FILA (CHECK, UNIQUE, FK). Aquí no hay
--              funciones de negocio ni triggers. En particular, el CHECK de transaccion valida la
--              coherencia de una fila; que cada GRUPO de asientos cuadre (Σ D = Σ C) es de la
--              Etapa 2. Tampoco garantiza que todo CLIENTE tenga cuenta: el esquema solo asegura
--              "como máximo una"; "exactamente una" la garantiza registrar_usuario (E4), que crea
--              el usuario y su cuenta en la misma transacción.
-- Dependencias : 01_roles.sql, 02_tipos_dominios.sql.
-- Ejecución    : como superusuario (pgAdmin o "ctl apply"); los objetos quedan a nombre de
--                banco_owner. IDEMPOTENTE (CREATE ... IF NOT EXISTS, filas únicas con
--                ON CONFLICT DO NOTHING) y transaccional.
-- Verificar    : SELECT table_schema, table_name FROM information_schema.tables
--                WHERE table_schema IN ('public','audit') AND table_type = 'BASE TABLE' ORDER BY 1, 2;
-- ============================================================================

BEGIN;

-- El esquema public es del dueño de la BD (no de banco_owner): su comentario se fija antes de cambiar de rol.
COMMENT ON SCHEMA public IS 'Núcleo del banco: las 11 tablas del negocio, tipos/dominios y (en etapas posteriores) funciones, triggers y vistas.';

SET LOCAL ROLE banco_owner;

CREATE SCHEMA IF NOT EXISTS audit;

-- ----------------------------------------------------------------------------
-- usuario  (especialización disjunta y total: CLIENTE | ADMIN; discriminador = rol)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.usuario (
  id                    uuid              NOT NULL DEFAULT gen_random_uuid(),
  username              text              NOT NULL,
  password_hash         text              NOT NULL,
  nombres               text              NOT NULL,
  apellidos             text              NOT NULL,
  cedula                text              NOT NULL,
  correo                text              NOT NULL,
  telefono              text              NOT NULL,
  fecha_nacimiento      date              NOT NULL,
  rol                   public.rol_usuario    NOT NULL DEFAULT 'CLIENTE',
  estado                public.estado_usuario NOT NULL DEFAULT 'ACTIVO',
  correoverificado      boolean           NOT NULL DEFAULT false,
  codigo_referido       uuid              NOT NULL DEFAULT gen_random_uuid(),
  referido_por          uuid,
  bono_referido_pagado  boolean           NOT NULL DEFAULT false,
  creado_en             timestamptz       NOT NULL DEFAULT now(),
  CONSTRAINT pk_usuario PRIMARY KEY (id),
  CONSTRAINT uq_usuario_username        UNIQUE (username),
  CONSTRAINT uq_usuario_cedula          UNIQUE (cedula),
  CONSTRAINT uq_usuario_correo          UNIQUE (correo),
  CONSTRAINT uq_usuario_telefono        UNIQUE (telefono),
  CONSTRAINT uq_usuario_codigo_referido UNIQUE (codigo_referido),
  CONSTRAINT uq_usuario_id_rol          UNIQUE (id, rol),       -- destino de la FK compuesta de cuenta
  CONSTRAINT fk_usuario_referidor FOREIGN KEY (referido_por) REFERENCES public.usuario (id) ON DELETE SET NULL,
  CONSTRAINT ck_usuario_username        CHECK (username ~ '^[a-z][a-z0-9]{2,29}$'),
  CONSTRAINT ck_usuario_password_hash   CHECK (btrim(password_hash) <> ''),
  CONSTRAINT ck_usuario_textos_no_vacios CHECK (btrim(nombres) <> '' AND btrim(apellidos) <> ''),
  CONSTRAINT ck_usuario_cedula_digitos  CHECK (cedula ~ '^[0-9]+$'),
  CONSTRAINT ck_usuario_telefono_digitos CHECK (telefono ~ '^[0-9]+$'),
  CONSTRAINT ck_usuario_correo_formato  CHECK (correo ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  CONSTRAINT ck_usuario_correo_minusculas CHECK (correo = lower(correo)),
  CONSTRAINT ck_usuario_nacimiento_rango CHECK (fecha_nacimiento >= DATE '1900-01-01'),
  CONSTRAINT ck_usuario_no_se_refiere_a_si_mismo CHECK (referido_por IS NULL OR referido_por <> id),
  CONSTRAINT ck_usuario_subtipo CHECK (rol = 'CLIENTE' OR (referido_por IS NULL AND bono_referido_pagado = false))
);

-- ----------------------------------------------------------------------------
-- cuenta  (solo CLIENTE: FK compuesta (usuario_id, rol) -> usuario(id, rol) con rol fijado a CLIENTE)
-- "Como máximo una por usuario" lo garantiza UNIQUE(usuario_id); "exactamente una" NO la garantiza
-- el esquema: la garantiza registrar_usuario (E4).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cuenta (
  id             uuid            NOT NULL DEFAULT gen_random_uuid(),
  usuario_id     uuid            NOT NULL,
  rol            public.rol_usuario NOT NULL DEFAULT 'CLIENTE',
  numero_cuenta  text            NOT NULL,
  balance        public.dinero   NOT NULL DEFAULT 0,
  creado_en      timestamptz     NOT NULL DEFAULT now(),
  CONSTRAINT pk_cuenta PRIMARY KEY (id),
  CONSTRAINT uq_cuenta_usuario UNIQUE (usuario_id),
  CONSTRAINT uq_cuenta_numero  UNIQUE (numero_cuenta),
  CONSTRAINT fk_cuenta_usuario FOREIGN KEY (usuario_id, rol) REFERENCES public.usuario (id, rol) ON DELETE CASCADE,
  CONSTRAINT ck_cuenta_rol_cliente CHECK (rol = 'CLIENTE'),
  CONSTRAINT ck_cuenta_numero_formato CHECK (numero_cuenta ~ '^[0-9]{10}$'),
  CONSTRAINT ck_cuenta_balance_no_negativo CHECK (balance >= 0)
);

-- ----------------------------------------------------------------------------
-- bolsillo  (varios por cuenta; el spec NO exige nombres únicos, por eso no hay UNIQUE sobre nombre)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bolsillo (
  id            uuid          NOT NULL DEFAULT gen_random_uuid(),
  cuenta_id     uuid          NOT NULL,
  nombre        text          NOT NULL,
  balance       public.dinero NOT NULL DEFAULT 0,
  ultimo_cobro  date          NOT NULL,
  creado_en     timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT pk_bolsillo PRIMARY KEY (id),
  CONSTRAINT fk_bolsillo_cuenta FOREIGN KEY (cuenta_id) REFERENCES public.cuenta (id) ON DELETE CASCADE,
  CONSTRAINT ck_bolsillo_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  CONSTRAINT ck_bolsillo_balance_no_negativo CHECK (balance >= 0)
);

-- ----------------------------------------------------------------------------
-- cdt_definicion
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cdt_definicion (
  id          uuid              NOT NULL DEFAULT gen_random_uuid(),
  nombre      text              NOT NULL,
  plazo_dias  integer           NOT NULL,
  tasa_anual  public.porcentaje NOT NULL,
  monto_min   public.dinero     NOT NULL,
  CONSTRAINT pk_cdt_definicion PRIMARY KEY (id),
  CONSTRAINT uq_cdt_definicion_nombre UNIQUE (nombre),
  CONSTRAINT ck_cdt_definicion_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  CONSTRAINT ck_cdt_definicion_plazo CHECK (plazo_dias > 0),
  CONSTRAINT ck_cdt_definicion_monto_min CHECK (monto_min > 0)
);

-- ----------------------------------------------------------------------------
-- cdt
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cdt (
  id                  uuid              NOT NULL DEFAULT gen_random_uuid(),
  cuenta_id           uuid              NOT NULL,
  definicion_id       uuid,
  nombre              text              NOT NULL,
  monto               public.dinero     NOT NULL,
  tasa_anual          public.porcentaje NOT NULL,
  plazo_dias          integer           NOT NULL,
  fecha_inicio        date              NOT NULL,
  fecha_fin           date              NOT NULL,
  generado_acumulado  public.dinero     NOT NULL DEFAULT 0,
  ultimo_cobro        date              NOT NULL,
  estado              public.estado_cdt NOT NULL DEFAULT 'ACTIVO',
  CONSTRAINT pk_cdt PRIMARY KEY (id),
  CONSTRAINT fk_cdt_cuenta     FOREIGN KEY (cuenta_id)     REFERENCES public.cuenta (id) ON DELETE CASCADE,
  CONSTRAINT fk_cdt_definicion FOREIGN KEY (definicion_id) REFERENCES public.cdt_definicion (id) ON DELETE SET NULL,
  CONSTRAINT ck_cdt_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  CONSTRAINT ck_cdt_monto_positivo CHECK (monto > 0),
  CONSTRAINT ck_cdt_plazo_positivo CHECK (plazo_dias > 0),
  CONSTRAINT ck_cdt_generado_no_negativo CHECK (generado_acumulado >= 0),
  CONSTRAINT ck_cdt_fechas_coherentes CHECK (fecha_fin = fecha_inicio + plazo_dias),
  CONSTRAINT ck_cdt_ultimo_cobro CHECK (ultimo_cobro >= fecha_inicio)
);

-- ----------------------------------------------------------------------------
-- credito_producto
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.credito_producto (
  id                     uuid              NOT NULL DEFAULT gen_random_uuid(),
  nombre                 text              NOT NULL,
  descripcion            text              NOT NULL DEFAULT '',
  tasa_anual             public.porcentaje NOT NULL,
  monto_min              public.dinero     NOT NULL,
  monto_max              public.dinero     NOT NULL,
  plazo_min_meses        integer           NOT NULL DEFAULT 1,
  plazo_max_meses        integer           NOT NULL,
  tope_absoluto          public.dinero,
  multiplicador_balance  numeric(8,2),
  aplica_regla_edad      boolean           NOT NULL DEFAULT false,
  CONSTRAINT pk_credito_producto PRIMARY KEY (id),
  CONSTRAINT uq_credito_producto_nombre UNIQUE (nombre),
  CONSTRAINT ck_credito_producto_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  CONSTRAINT ck_credito_producto_montos CHECK (monto_min > 0 AND monto_min <= monto_max),
  CONSTRAINT ck_credito_producto_plazos CHECK (plazo_min_meses >= 1 AND plazo_min_meses <= plazo_max_meses),
  CONSTRAINT ck_credito_producto_tope CHECK (tope_absoluto IS NULL OR tope_absoluto > 0),
  CONSTRAINT ck_credito_producto_multiplicador CHECK (multiplicador_balance IS NULL OR multiplicador_balance > 0)
);

-- ----------------------------------------------------------------------------
-- credito
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.credito (
  id                    uuid              NOT NULL DEFAULT gen_random_uuid(),
  cuenta_id             uuid              NOT NULL,
  producto_id           uuid              NOT NULL,
  monto                 public.dinero     NOT NULL,
  tasa_anual            public.porcentaje NOT NULL,
  plazo_meses           integer           NOT NULL,
  fecha_desembolso      date              NOT NULL,
  capital_pendiente     public.dinero     NOT NULL,
  descuento_automatico  boolean           NOT NULL DEFAULT false,
  mora_acumulada        public.dinero     NOT NULL DEFAULT 0,
  fecha_interes         date              NOT NULL,
  estado                public.estado_credito NOT NULL DEFAULT 'ACTIVO',
  CONSTRAINT pk_credito PRIMARY KEY (id),
  CONSTRAINT fk_credito_cuenta   FOREIGN KEY (cuenta_id)   REFERENCES public.cuenta (id) ON DELETE CASCADE,
  CONSTRAINT fk_credito_producto FOREIGN KEY (producto_id) REFERENCES public.credito_producto (id),
  CONSTRAINT ck_credito_monto_positivo CHECK (monto > 0),
  CONSTRAINT ck_credito_plazo_positivo CHECK (plazo_meses >= 1),
  CONSTRAINT ck_credito_capital_rango CHECK (capital_pendiente >= 0 AND capital_pendiente <= monto),
  CONSTRAINT ck_credito_pagado_sin_deuda CHECK (estado <> 'PAGADO' OR capital_pendiente = 0),
  CONSTRAINT ck_credito_mora_no_negativa CHECK (mora_acumulada >= 0)
);

-- La regla "un crédito vivo por producto" queda en el esquema, no solo en una función.
CREATE UNIQUE INDEX IF NOT EXISTS uq_credito_vivo_por_producto
  ON public.credito (cuenta_id, producto_id) WHERE estado = 'ACTIVO';

-- ----------------------------------------------------------------------------
-- cuota  (ENTIDAD DÉBIL de credito: clave real = (credito_id, numero); id es sustituto)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cuota (
  id                    uuid          NOT NULL DEFAULT gen_random_uuid(),
  credito_id            uuid          NOT NULL,
  numero                integer       NOT NULL,
  fecha_vencimiento     date          NOT NULL,
  valor_cuota_original  public.dinero NOT NULL,
  valor_cuota           public.dinero NOT NULL,
  capital_programado    public.dinero NOT NULL,
  interes_programado    public.dinero NOT NULL,
  capital_pagado        public.dinero NOT NULL DEFAULT 0,
  intereses_pagados     public.dinero NOT NULL DEFAULT 0,
  fecha_pago            date,
  pagada                boolean       NOT NULL DEFAULT false,
  CONSTRAINT pk_cuota PRIMARY KEY (id),
  CONSTRAINT uq_cuota_credito_numero UNIQUE (credito_id, numero),
  CONSTRAINT fk_cuota_credito FOREIGN KEY (credito_id) REFERENCES public.credito (id) ON DELETE CASCADE,
  CONSTRAINT ck_cuota_numero_positivo CHECK (numero >= 1),
  CONSTRAINT ck_cuota_valores_positivos CHECK (valor_cuota_original > 0 AND valor_cuota > 0),
  CONSTRAINT ck_cuota_desglose CHECK (capital_programado >= 0 AND interes_programado >= 0
                                      AND valor_cuota = capital_programado + interes_programado),
  CONSTRAINT ck_cuota_pagos_no_negativos CHECK (capital_pagado >= 0 AND intereses_pagados >= 0),
  CONSTRAINT ck_cuota_pagada_con_fecha CHECK (pagada = (fecha_pago IS NOT NULL))
);

-- ----------------------------------------------------------------------------
-- transaccion  (libro mayor; generalización disjunta y total por tipo; una fila = una "pata")
-- Los CHECK validan CADA FILA. El cuadre del grupo (Σ D = Σ C por grupo_id) es de la Etapa 2.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.transaccion (
  id                  uuid                       NOT NULL DEFAULT gen_random_uuid(),
  orden               bigint                     GENERATED ALWAYS AS IDENTITY,
  grupo_id            uuid                       NOT NULL,
  fecha               timestamptz                NOT NULL,
  tipo                public.tipo_transaccion    NOT NULL,
  contenedor          public.contenedor_contable NOT NULL,
  sentido             public.sentido_asiento     NOT NULL,
  lado                char(1) GENERATED ALWAYS AS (
                        CASE WHEN contenedor IN ('CUENTA', 'BOLSILLO', 'CDT')
                             THEN CASE WHEN sentido = 'E' THEN 'D' ELSE 'C' END
                             ELSE CASE WHEN sentido = 'E' THEN 'C' ELSE 'D' END
                        END) STORED,
  monto               public.dinero              NOT NULL,
  saldo_previo        public.dinero,
  saldo_posterior     public.dinero,
  nota                text,
  cuenta_id           uuid                       NOT NULL,
  bolsillo_id         uuid,
  cdt_id              uuid,
  credito_id          uuid,
  contraparte_nombre  text,
  contraparte_cuenta  text,
  CONSTRAINT pk_transaccion PRIMARY KEY (id),
  CONSTRAINT uq_transaccion_orden UNIQUE (orden),
  CONSTRAINT fk_transaccion_cuenta   FOREIGN KEY (cuenta_id)   REFERENCES public.cuenta (id) ON DELETE CASCADE,
  -- NO ACTION (no CASCADE): impide borrar un bolsillo/CDT/crédito suelto que tenga asientos.
  -- Borrar al usuario sí funciona: la cascada elimina los asientos por cuenta_id en la misma sentencia.
  CONSTRAINT fk_transaccion_bolsillo FOREIGN KEY (bolsillo_id) REFERENCES public.bolsillo (id),
  CONSTRAINT fk_transaccion_cdt      FOREIGN KEY (cdt_id)      REFERENCES public.cdt (id),
  CONSTRAINT fk_transaccion_credito  FOREIGN KEY (credito_id)  REFERENCES public.credito (id),
  CONSTRAINT ck_transaccion_monto_positivo CHECK (monto > 0),
  -- Matriz contable (D2): las únicas 37 combinaciones (tipo, contenedor, sentido) permitidas.
  CONSTRAINT ck_transaccion_tipo_contenedor_sentido CHECK ((tipo::text, contenedor::text, sentido::text) IN (
    ('ENVIO','CUENTA','S'),              ('ENVIO','BOLSILLO','S'),
    ('RECIBO','CUENTA','E'),
    ('BOLSO_INGRESO','CUENTA','S'),      ('BOLSO_INGRESO','BOLSILLO','E'),
    ('BOLSO_RETIRO','BOLSILLO','S'),     ('BOLSO_RETIRO','CUENTA','E'),
    ('BOLSO_MOVIMIENTO','BOLSILLO','S'), ('BOLSO_MOVIMIENTO','BOLSILLO','E'),
    ('INTERES_BOLSO','BOLSILLO','E'),    ('INTERES_BOLSO','RESULTADO','E'),
    ('CDT_CREACION','CUENTA','S'),       ('CDT_CREACION','CDT','E'),
    ('INTERES_CDT','CDT','E'),           ('INTERES_CDT','RESULTADO','E'),
    ('CDT_VENCIMIENTO','CDT','S'),       ('CDT_VENCIMIENTO','CUENTA','E'),
    ('CREDITO_DESEMBOLSO','CUENTA','E'), ('CREDITO_DESEMBOLSO','CREDITO','E'),
    ('CREDITO_CUOTA','CUENTA','S'),      ('CREDITO_CUOTA','CREDITO','S'),      ('CREDITO_CUOTA','RESULTADO','S'),
    ('CREDITO_ABONO','CUENTA','S'),      ('CREDITO_ABONO','CREDITO','S'),      ('CREDITO_ABONO','RESULTADO','S'),
    ('CREDITO_MORA','CUENTA','S'),       ('CREDITO_MORA','RESULTADO','S'),
    ('INGRESO_SIMULADO','CUENTA','E'),   ('INGRESO_SIMULADO','RESULTADO','E'),
    ('BONO_REFERIDO','CUENTA','E'),      ('BONO_REFERIDO','RESULTADO','E'),
    ('DEPOSITO_BANCO','CUENTA','E'),     ('DEPOSITO_BANCO','RESULTADO','E'),
    ('AJUSTE_ADMIN','CUENTA','E'),       ('AJUSTE_ADMIN','CUENTA','S'),
    ('AJUSTE_ADMIN','RESULTADO','E'),    ('AJUSTE_ADMIN','RESULTADO','S')
  )),
  -- Cada id de producto solo aparece en tipos de su familia y es obligatorio en ella. Junto con la matriz
  -- esto implica que un contenedor BOLSILLO/CDT/CREDITO siempre apunta a su producto.
  CONSTRAINT ck_transaccion_cdt_id_familia CHECK (
        (cdt_id IS NULL OR tipo::text IN ('CDT_CREACION','CDT_VENCIMIENTO','INTERES_CDT'))
    AND (tipo::text NOT IN ('CDT_CREACION','CDT_VENCIMIENTO','INTERES_CDT') OR cdt_id IS NOT NULL)),
  CONSTRAINT ck_transaccion_credito_id_familia CHECK (
        (credito_id IS NULL OR tipo::text IN ('CREDITO_DESEMBOLSO','CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA'))
    AND (tipo::text NOT IN ('CREDITO_DESEMBOLSO','CREDITO_CUOTA','CREDITO_ABONO','CREDITO_MORA') OR credito_id IS NOT NULL)),
  CONSTRAINT ck_transaccion_bolsillo_id_familia CHECK (
        (bolsillo_id IS NULL OR tipo::text IN ('ENVIO','BOLSO_INGRESO','BOLSO_RETIRO','BOLSO_MOVIMIENTO','INTERES_BOLSO'))
    AND (tipo::text NOT IN ('BOLSO_INGRESO','BOLSO_RETIRO','BOLSO_MOVIMIENTO','INTERES_BOLSO') OR bolsillo_id IS NOT NULL)
    AND (tipo::text <> 'ENVIO' OR ((contenedor::text = 'BOLSILLO') = (bolsillo_id IS NOT NULL)))),
  -- Saldos: los contenedores almacenados (CUENTA, BOLSILLO, CREDITO) registran saldo previo y posterior
  -- (posterior = previo ± monto según el sentido); los derivados (CDT, RESULTADO) los dejan en NULL.
  CONSTRAINT ck_transaccion_saldos CHECK (
       (contenedor::text IN ('CUENTA','BOLSILLO','CREDITO')
        AND saldo_previo IS NOT NULL AND saldo_posterior IS NOT NULL
        AND saldo_previo >= 0 AND saldo_posterior >= 0
        AND saldo_posterior = saldo_previo + CASE WHEN sentido::text = 'E' THEN monto ELSE -monto END)
    OR (contenedor::text IN ('CDT','RESULTADO') AND saldo_previo IS NULL AND saldo_posterior IS NULL))
);

-- ----------------------------------------------------------------------------
-- reloj  (fila única: el reloj del banco)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reloj (
  id               smallint NOT NULL DEFAULT 1,
  usar_fecha_real  boolean  NOT NULL DEFAULT true,
  fecha_sistema    date,
  CONSTRAINT pk_reloj PRIMARY KEY (id),
  CONSTRAINT ck_reloj_fila_unica CHECK (id = 1),
  CONSTRAINT ck_reloj_fecha_si_manual CHECK (usar_fecha_real OR fecha_sistema IS NOT NULL)
);

-- ----------------------------------------------------------------------------
-- parametro  (fila única: parámetros globales; solo la mora es editable por el admin)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.parametro (
  id                           smallint          NOT NULL DEFAULT 1,
  tasa_mora_anual              public.porcentaje,                         -- sin valor hasta que el equipo decida (D7/D11)
  tasa_bolsillo_anual          public.porcentaje NOT NULL DEFAULT 12,     -- spec §7.4
  bono_referido                public.dinero     NOT NULL DEFAULT 50000,  -- spec §7.1
  edad_limite_inmuebles        smallint          NOT NULL DEFAULT 70,     -- spec §7.6
  ingresos_simulados_cantidad  smallint          NOT NULL DEFAULT 5,      -- spec §7.1
  ingreso_simulado_min         public.dinero     NOT NULL DEFAULT 10000,  -- spec §7.1
  ingreso_simulado_max         public.dinero     NOT NULL DEFAULT 1000000,-- spec §7.1
  monto_maximo                 public.dinero     NOT NULL DEFAULT 9999999999999.99,  -- tope técnico de cualquier importe
  CONSTRAINT pk_parametro PRIMARY KEY (id),
  CONSTRAINT ck_parametro_fila_unica CHECK (id = 1),
  CONSTRAINT ck_parametro_valores_positivos CHECK (bono_referido > 0 AND edad_limite_inmuebles > 0
                                                   AND ingresos_simulados_cantidad >= 0 AND monto_maximo > 0),
  CONSTRAINT ck_parametro_rango_simulado CHECK (ingreso_simulado_min > 0 AND ingreso_simulado_min <= ingreso_simulado_max)
);

-- ----------------------------------------------------------------------------
-- audit.evento  (bitácora; SIN FKs: sobrevive al borrado de usuarios)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.evento (
  id              uuid        NOT NULL DEFAULT gen_random_uuid(),
  orden           bigint      GENERATED ALWAYS AS IDENTITY,
  fecha           timestamptz NOT NULL DEFAULT now(),
  actor_id        uuid,
  actor_username  text,
  accion          text        NOT NULL,
  entidad         text,
  entidad_id      text,
  antes           jsonb,
  despues         jsonb,
  CONSTRAINT pk_evento PRIMARY KEY (id),
  CONSTRAINT uq_evento_orden UNIQUE (orden),
  CONSTRAINT ck_evento_accion_no_vacia CHECK (btrim(accion) <> '')
);

-- ----------------------------------------------------------------------------
-- Filas únicas (estructura, no negocio): el reloj en modo real y los parámetros del spec.
-- ----------------------------------------------------------------------------
INSERT INTO public.reloj (id, usar_fecha_real) VALUES (1, true) ON CONFLICT (id) DO NOTHING;
INSERT INTO public.parametro (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Documentación de tablas y columnas (visible en pgAdmin > Properties > Comment)
-- ----------------------------------------------------------------------------
COMMENT ON SCHEMA audit IS 'Auditoría del banco. Fuera del alcance del backend: solo la escriben funciones/triggers del propietario; banco_lector puede leerla.';

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public','usuario','Usuario del banco. Especialización disjunta y total: CLIENTE (posee cuenta y productos) o ADMIN (opera el banco, sin cuenta); discriminador = rol.'),
    ('public','cuenta','Cuenta principal de un CLIENTE (como máximo una por usuario; que exista siempre la garantiza registrar_usuario, E4). Su balance es un acumulador del libro mayor.'),
    ('public','bolsillo','Bolsillo de ahorro de una cuenta (varios por cuenta; el nombre no es único). Su balance es un acumulador y rinde interés diario por cobro lazy.'),
    ('public','cdt_definicion','Plantilla ofertada de CDT (nombre, plazo, tasa y monto mínimo), editable por el admin. Los CDT creados guardan copias de sus valores.'),
    ('public','cdt','CDT de una cuenta: principal bloqueado hasta el vencimiento; el interés devengado se acumula en generado_acumulado.'),
    ('public','credito_producto','Producto de crédito ofertado (tasa, rango de monto y plazo, topes y regla de edad), editable por el admin.'),
    ('public','credito','Crédito de una cuenta. capital_pendiente es un acumulador (pasivo). Un solo crédito ACTIVO por producto y cuenta.'),
    ('public','cuota','Cuota del plan de pagos de un crédito. ENTIDAD DÉBIL: su clave real es (credito_id, numero) y no existe sin el crédito.'),
    ('public','transaccion','Libro mayor. Cada fila es una pata de una operación (grupo_id) que afecta un contenedor contable con un sentido. Generalización por tipo (17 tipos, 5 familias). Inmutable (desde E2).'),
    ('public','reloj','Reloj del banco (fila única). Modo real: el "hoy" es la fecha actual de America/Bogota (sin desfase; fecha_sistema NULL). Modo manual: el "hoy" es fecha_sistema, que solo puede adelantarse (El reloj no puede retroceder). Volver a modo real siempre se permite: es una salida explícita de la simulación y NO revierte nada del historial (E3).'),
    ('public','parametro','Parámetros globales del banco (fila única). Solo la tasa de mora es editable por el admin.'),
    ('audit','evento','Bitácora de auditoría. Sin claves foráneas: el actor y la entidad se guardan como snapshot y sobreviven al borrado de usuarios.')
  ) AS v(esquema, tabla, texto) LOOP
    EXECUTE format('COMMENT ON TABLE %I.%I IS %L', r.esquema, r.tabla, r.texto);
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public','usuario','id','Identidad opaca (UUID); no hay ids secuenciales visibles.'),
    ('public','usuario','username','Llave de login, en minúsculas y dígitos (3 a 30). La regla de generación la aplica registrar_usuario (E4).'),
    ('public','usuario','password_hash','Hash bcrypt calculado en el backend; la BD nunca ve la contraseña en claro. banco_lector no puede leerlo.'),
    ('public','usuario','nombres','Nombres del usuario.'),
    ('public','usuario','apellidos','Apellidos del usuario.'),
    ('public','usuario','cedula','Documento de identidad (solo dígitos, único).'),
    ('public','usuario','correo','Correo electrónico en minúsculas (único).'),
    ('public','usuario','telefono','Teléfono (solo dígitos, único).'),
    ('public','usuario','fecha_nacimiento','Fecha de nacimiento; base de la regla de edad de Inmuebles.'),
    ('public','usuario','rol','Discriminador de la especialización: CLIENTE o ADMIN.'),
    ('public','usuario','estado','ACTIVO o BLOQUEADO.'),
    ('public','usuario','correoverificado','Si el correo fue verificado (nombre tomado del spec §5). Dispara el bono de referido.'),
    ('public','usuario','codigo_referido','Código público (UUID) que el usuario comparte para referir a otros.'),
    ('public','usuario','referido_por','Usuario que lo refirió (auto-FK, SET NULL al borrarlo). Solo CLIENTE.'),
    ('public','usuario','bono_referido_pagado','Idempotencia del bono de referido. Solo CLIENTE.'),
    ('public','usuario','creado_en','Marca técnica de alta (las funciones de negocio usarán el reloj del banco).'),
    ('public','cuenta','id','Identidad de la cuenta; propietaria de bolsillos, productos y asientos.'),
    ('public','cuenta','usuario_id','Dueño de la cuenta (único: como máximo una cuenta por usuario).'),
    ('public','cuenta','rol','Columna de subtipo: junto a usuario_id forma la FK compuesta; el CHECK la fija a CLIENTE, así un ADMIN no puede tener cuenta.'),
    ('public','cuenta','numero_cuenta','Número de 10 dígitos, único y visible al usuario; destino de las transferencias.'),
    ('public','cuenta','balance','ACUMULADOR del saldo principal (>= 0). Solo lo moverá el libro mayor (E2).'),
    ('public','cuenta','creado_en','Marca técnica de alta.'),
    ('public','bolsillo','id','Identidad del bolsillo.'),
    ('public','bolsillo','cuenta_id','Cuenta propietaria.'),
    ('public','bolsillo','nombre','Nombre dado por el usuario (no vacío; puede repetirse).'),
    ('public','bolsillo','balance','ACUMULADOR del saldo del bolsillo (>= 0).'),
    ('public','bolsillo','ultimo_cobro','Último día hasta el que se devengó interés (cobro lazy).'),
    ('public','bolsillo','creado_en','Marca técnica de alta.'),
    ('public','cdt_definicion','id','Identidad de la plantilla.'),
    ('public','cdt_definicion','nombre','Nombre mostrado, único.'),
    ('public','cdt_definicion','plazo_dias','Plazo en días (> 0).'),
    ('public','cdt_definicion','tasa_anual','Tasa como porcentaje; editable por el admin; se copia al crear el CDT.'),
    ('public','cdt_definicion','monto_min','Monto mínimo para abrir el CDT (> 0).'),
    ('public','cdt','id','Identidad del CDT.'),
    ('public','cdt','cuenta_id','Cuenta propietaria.'),
    ('public','cdt','definicion_id','Plantilla de origen (SET NULL si se borra); solo trazabilidad, el CDT conserva sus copias.'),
    ('public','cdt','nombre','Nombre copiado de la plantilla.'),
    ('public','cdt','monto','Principal bloqueado (> 0, inmutable desde E2).'),
    ('public','cdt','tasa_anual','Tasa copiada al crear; no cambia si el admin edita la plantilla.'),
    ('public','cdt','plazo_dias','Plazo copiado al crear.'),
    ('public','cdt','fecha_inicio','Fecha de apertura (reloj del banco).'),
    ('public','cdt','fecha_fin','Vencimiento; siempre fecha_inicio + plazo_dias.'),
    ('public','cdt','generado_acumulado','ACUMULADOR del interés devengado (suma de asientos INTERES_CDT; no decrece).'),
    ('public','cdt','ultimo_cobro','Último día hasta el que se devengó interés (cobro lazy).'),
    ('public','cdt','estado','ACTIVO hasta el vencimiento; luego CERRADO.'),
    ('public','credito_producto','id','Identidad del producto.'),
    ('public','credito_producto','nombre','Nombre del producto, único.'),
    ('public','credito_producto','descripcion','Texto para la landing.'),
    ('public','credito_producto','tasa_anual','Tasa como porcentaje; editable por el admin; se copia al crear el crédito.'),
    ('public','credito_producto','monto_min','Monto mínimo base (> 0).'),
    ('public','credito_producto','monto_max','Monto máximo base (>= monto_min).'),
    ('public','credito_producto','plazo_min_meses','Plazo mínimo en meses (contrato §4).'),
    ('public','credito_producto','plazo_max_meses','Plazo máximo base en meses.'),
    ('public','credito_producto','tope_absoluto','Tope fijo de monto; NULL si no aplica.'),
    ('public','credito_producto','multiplicador_balance','Veces el balance total como tope (100 en Inmuebles); NULL si no aplica.'),
    ('public','credito_producto','aplica_regla_edad','Si aplica la regla edad + años <= límite.'),
    ('public','credito','id','Identidad del crédito.'),
    ('public','credito','cuenta_id','Cuenta propietaria.'),
    ('public','credito','producto_id','Producto contratado; no se puede borrar un producto con créditos.'),
    ('public','credito','monto','Principal desembolsado (> 0).'),
    ('public','credito','tasa_anual','Tasa copiada al crear.'),
    ('public','credito','plazo_meses','Plazo pactado en meses.'),
    ('public','credito','fecha_desembolso','Fecha del desembolso (reloj del banco).'),
    ('public','credito','capital_pendiente','ACUMULADOR (pasivo) de la deuda de capital; entre 0 y monto.'),
    ('public','credito','descuento_automatico','Si el cobro lazy debita las cuotas al vencer.'),
    ('public','credito','mora_acumulada','Columna del spec §5; su definición y uso quedan sujetos a la decisión D7 del equipo.'),
    ('public','credito','fecha_interes','Corte hasta el que se devengó interés (spec §8).'),
    ('public','credito','estado','ACTIVO mientras haya deuda; luego PAGADO (capital_pendiente = 0).'),
    ('public','cuota','id','Identidad sustituta (convención UUID); la clave real es (credito_id, numero).'),
    ('public','cuota','credito_id','Crédito del que depende (relación identificante, ON DELETE CASCADE).'),
    ('public','cuota','numero','Clave parcial: número de cuota dentro del crédito (>= 1).'),
    ('public','cuota','fecha_vencimiento','Fecha en que vence la cuota.'),
    ('public','cuota','valor_cuota_original','Valor de la cuota en el plan original (spec §5).'),
    ('public','cuota','valor_cuota','Valor vigente de la cuota (cambia al recalcular tras un abono).'),
    ('public','cuota','capital_programado','Parte de capital del plan vigente.'),
    ('public','cuota','interes_programado','Parte de interés del plan vigente; capital + interés = valor_cuota.'),
    ('public','cuota','capital_pagado','Capital realmente pagado.'),
    ('public','cuota','intereses_pagados','Intereses realmente pagados.'),
    ('public','cuota','fecha_pago','Fecha de pago; NULL si no se ha pagado.'),
    ('public','cuota','pagada','Si está pagada; coherente con fecha_pago.'),
    ('public','transaccion','id','Identidad de la pata.'),
    ('public','transaccion','orden','Orden real de inserción (identity); el historial se ordena por esta columna, no por fecha.'),
    ('public','transaccion','grupo_id','Une las patas de una misma operación (el cuadre por grupo se valida en E2).'),
    ('public','transaccion','fecha','Fecha y hora de negocio (reloj del banco).'),
    ('public','transaccion','tipo','Discriminador de la generalización: los 17 tipos del contrato.'),
    ('public','transaccion','contenedor','Acumulador que afecta la pata: CUENTA, BOLSILLO, CDT, CREDITO o RESULTADO.'),
    ('public','transaccion','sentido','E = aumenta el acumulador del contenedor; S = lo disminuye.'),
    ('public','transaccion','lado','D/C derivado (columna generada): D si (CUENTA|BOLSILLO|CDT, E) o (CREDITO|RESULTADO, S); C en los demás casos. Base del cuadre ΣD = ΣC.'),
    ('public','transaccion','monto','Importe positivo de la pata.'),
    ('public','transaccion','saldo_previo','Saldo del contenedor antes de la pata (solo CUENTA, BOLSILLO, CREDITO; NULL en CDT y RESULTADO).'),
    ('public','transaccion','saldo_posterior','Saldo del contenedor después de la pata (solo CUENTA, BOLSILLO, CREDITO).'),
    ('public','transaccion','nota','Nota del usuario o del admin.'),
    ('public','transaccion','cuenta_id','Cuenta propietaria de la pata (para la cascada y la propiedad).'),
    ('public','transaccion','bolsillo_id','Bolsillo afectado o referenciado (según tipo y contenedor).'),
    ('public','transaccion','cdt_id','CDT afectado (tipos de la familia CDT).'),
    ('public','transaccion','credito_id','Crédito afectado (tipos de la familia Crédito).'),
    ('public','transaccion','contraparte_nombre','Snapshot del nombre de la contraparte (otro cliente o "Banco Digital"); sin FK.'),
    ('public','transaccion','contraparte_cuenta','Snapshot del número de cuenta de la contraparte; sin FK.'),
    ('public','reloj','id','Fila única (siempre 1).'),
    ('public','reloj','usar_fecha_real','TRUE = fecha real de Colombia; FALSE = simulación con fecha_sistema. Pasar a TRUE siempre se permite (aunque la fecha real sea anterior a la simulada).'),
    ('public','reloj','fecha_sistema','Fecha simulada (solo en modo manual; obligatoria si usar_fecha_real es FALSE; entre 2000-01-01 y 2100-12-31). En modo real se fuerza a NULL. En modo manual solo puede igualarse o adelantarse.'),
    ('public','parametro','id','Fila única (siempre 1).'),
    ('public','parametro','tasa_mora_anual','Tasa de mora global (porcentaje), editable por el admin. Sin valor inicial hasta que el equipo decida (D7/D11).'),
    ('public','parametro','tasa_bolsillo_anual','Rentabilidad anual de los bolsillos (12 según el spec §7.4).'),
    ('public','parametro','bono_referido','Bono por referido (50.000 según el spec §7.1).'),
    ('public','parametro','edad_limite_inmuebles','Límite de la regla edad + años de plazo <= límite (70, spec §7.6).'),
    ('public','parametro','ingresos_simulados_cantidad','Cuántos INGRESO_SIMULADO se crean al registrar (5, spec §7.1).'),
    ('public','parametro','ingreso_simulado_min','Mínimo de cada ingreso simulado (10.000, spec §7.1).'),
    ('public','parametro','ingreso_simulado_max','Máximo de cada ingreso simulado (1.000.000, spec §7.1).'),
    ('public','parametro','monto_maximo','Tope técnico de cualquier importe (< 10^13) para el transporte sin pérdida de centavos.'),
    ('audit','evento','id','Identidad del evento.'),
    ('audit','evento','orden','Orden de ocurrencia (identity).'),
    ('audit','evento','fecha','Momento del hecho (marca técnica).'),
    ('audit','evento','actor_id','Quién actuó (UUID sin FK; NULL si fue el sistema).'),
    ('audit','evento','actor_username','Snapshot del username del actor; sobrevive al borrado del usuario.'),
    ('audit','evento','accion','Qué ocurrió (por ejemplo USUARIO_BLOQUEADO).'),
    ('audit','evento','entidad','Tabla o entidad afectada.'),
    ('audit','evento','entidad_id','Id de la entidad como texto (puede ser smallint en los singleton).'),
    ('audit','evento','antes','Estado anterior (jsonb).'),
    ('audit','evento','despues','Estado posterior (jsonb).')
  ) AS v(esquema, tabla, columna, texto) LOOP
    EXECUTE format('COMMENT ON COLUMN %I.%I.%I IS %L', r.esquema, r.tabla, r.columna, r.texto);
  END LOOP;
END
$$;

COMMIT;
