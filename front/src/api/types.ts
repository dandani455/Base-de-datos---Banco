// Formas de respuesta asumidas del backend (a alinear luego). El front solo las muestra.
export type Yo = { username: string };

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
