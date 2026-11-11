// Formas de respuesta asumidas del backend (a alinear luego). El front solo las muestra.
export type Yo = { username: string; rol?: 'ADMIN' | 'CLIENTE' };

export type Transaccion = {
  id: string | number;
  tipo: 'envio' | 'recibo';
  monto: number;
  fecha: string;
  contraparte?: string;
  nota?: string;
};

export type Dashboard = {
  nombre: string;
  balance_total: number;
  transacciones: Transaccion[];
  cdts: { activos: number; generado: number };
  creditos: { cuota_por_pagar: number; interes_corriendo: number };
};

export type Bolsillo = { id: string | number; nombre: string; saldo: number };
export type Balance = { total: number; principal: number; bolsillos: Bolsillo[] };

export type Destinatario = { nombre: string };

export type ProductoCredito = {
  id: string | number; nombre: string; tasa: string | number;
  monto_min: number; monto_max: number; plazo_min: number; plazo_max: number;
};
export type SimulacionCredito = { cuota_mensual: number; total_a_pagar: number; intereses_totales: number };
export type MiCredito = {
  id: string | number; producto: string; cuotas_pagadas: number; cuotas_faltantes: number;
  interes_mes: number; saldo?: number;
};

export type DefinicionCdt = { id: string | number; nombre: string; tasa: string | number; plazo_dias: number; monto_min: number };
export type SimulacionCdt = { generado_mes: number; generado_dia: number; generado_vencimiento: number };
export type MiCdt = {
  id: string | number; monto: number; generado_hasta_hoy: number; tiempo_restante: string; fecha_cierre: string;
};

export type Perfil = { username: string; numero_cuenta: string; codigo_referido: string };

// ---- Admin (contrato asumido; lo implementa el backend) ----
export type AdminUsuario = {
  id: string | number; username: string; nombre: string; cedula: string; correo: string;
  numero_cuenta: string; estado: 'ACTIVO' | 'BLOQUEADO';
};
export type AdminUsuarioDetalle = AdminUsuario & {
  balance: {
    total: number; principal: number; bolsillos: Bolsillo[];
    cdts: { id: string | number; monto: number }[];
    creditos: { id: string | number; producto: string; saldo: number }[];
  };
  historial: Transaccion[];
};
export type AdminReloj = { usar_fecha_real: boolean; fecha_sistema: string; fecha_actual: string };
export type AdminTasas = {
  cdts: { id: string | number; nombre: string; tasa: string | number }[];
  creditos: { id: string | number; nombre: string; tasa: string | number }[];
  mora: string | number;
};
export type EsquemaColumna = { nombre: string; tipo?: string; llave?: boolean; unico?: boolean; no_nulo?: boolean };
export type EsquemaFk = { columna: string; tabla_destino: string; columna_destino?: string };
export type EsquemaTabla = { nombre: string; columnas: EsquemaColumna[]; fks: EsquemaFk[] };
export type Esquema = { tablas: EsquemaTabla[] };
export type PaginaTabla = { columnas: string[]; filas: Record<string, unknown>[]; pagina: number; total_paginas: number };
