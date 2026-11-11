// Servidor mock SOLO para desarrollo: permite ver el front sin backend. Node 22, sin dependencias.
import http from 'node:http';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.MOCK_PORT ?? 3000);
const hoy = () => new Date().toISOString().slice(0, 10);
const redondea = (n) => Math.round(n);

// ---------- datos en memoria ----------
let nextId = 100;
const nuevoId = () => ++nextId;

function tx(id, dias, tipo, monto, contraparte, nota) {
  const f = new Date(Date.now() - dias * 86400000 - (id % 7) * 3600000);
  return { id, tipo, monto, fecha: f.toISOString(), contraparte, ...(nota ? { nota } : {}) };
}

const jperezTx = [
  tx(1, 0, 'recibo', 850000, 'Camila Rodríguez Peña', 'Arriendo compartido'),
  tx(2, 0, 'envio', 45000, 'Tienda Don Pepe', 'Mercado'),
  tx(3, 1, 'envio', 120000, 'Andrés Felipe Mora', 'Cena del viernes'),
  tx(4, 2, 'recibo', 2400000, 'Nómina Estudio Aurora SAS', 'Quincena'),
  tx(5, 3, 'envio', 38500, 'Juliana Cárdenas', ''),
  tx(6, 3, 'recibo', 60000, 'Santiago Gómez Ruiz', 'Mi parte del cumpleaños'),
  tx(7, 4, 'envio', 210000, 'Laura Valentina Ospina', 'Boletas concierto'),
  tx(8, 5, 'envio', 15000, 'Panadería La Esquina', ''),
  tx(9, 6, 'recibo', 150000, 'Mariana Torres Vélez', 'Gracias por el préstamo'),
  tx(10, 7, 'envio', 380000, 'Carlos Eduardo Beltrán', 'Cuota gimnasio'),
  tx(11, 8, 'envio', 72000, 'Daniela Herrera', ''),
  tx(12, 9, 'recibo', 500000, 'Sebastián Quintero', 'Venta bicicleta'),
  tx(13, 10, 'envio', 95000, 'Valeria Montoya', 'Regalo mamá'),
  tx(14, 12, 'recibo', 2400000, 'Nómina Estudio Aurora SAS', 'Quincena'),
  tx(15, 13, 'envio', 640000, 'Inmobiliaria Chapinero', 'Arriendo'),
  tx(16, 14, 'envio', 27000, 'Juan Sebastián Rojas', ''),
  tx(17, 15, 'recibo', 90000, 'Natalia Giraldo', 'Almuerzo'),
  tx(18, 17, 'envio', 54000, 'Tienda Don Pepe', 'Mercado'),
  tx(19, 19, 'recibo', 320000, 'Felipe Arango Duarte', ''),
  tx(20, 21, 'envio', 180000, 'Paula Andrea Vargas', 'Taller de cerámica'),
];

const usuarios = [
  {
    id: 1, username: 'jperez483', password: 'Banco2026', rol: 'CLIENTE', estado: 'ACTIVO',
    nombres: 'Juan', nombre: 'Juan Pérez Gutiérrez', cedula: '1020304050', correo: 'juan.perez@correo.co',
    telefono: '3001234567', numero_cuenta: '4001002003', codigo_referido: '8f3c2a10-5b7e-4d3a-9c21-6a7b1d0e42f9',
    principal: 3250000,
    bolsillos: [{ id: 11, nombre: 'Viaje a San Andrés', saldo: 900000 }, { id: 12, nombre: 'Fondo de emergencia', saldo: 1500000 }],
    cdts: [
      { id: 21, definicion_id: 1, monto: 2000000, tasa: 0.0925, plazo_dias: 90, abierto: -30, activo: true },
      { id: 22, definicion_id: 2, monto: 1000000, tasa: 0.10, plazo_dias: 60, abierto: -90, activo: false },
    ],
    creditos: [
      { id: 31, producto_id: 1, producto: 'Libre inversión', monto: 6000000, plazo: 24, tasa: 0.018, cuotas_pagadas: 5, saldo: 4900000 },
      { id: 32, producto_id: 3, producto: 'Vehículo', monto: 12000000, plazo: 48, tasa: 0.0145, cuotas_pagadas: 11, saldo: 9400000 },
    ],
    tx: jperezTx,
  },
  {
    id: 2, username: 'admin1', password: 'Banco2026', rol: 'ADMIN', estado: 'ACTIVO',
    nombres: 'Administración', nombre: 'Administración Banco', cedula: '900100200', correo: 'admin@bancodigital.co',
    telefono: '3100000000', numero_cuenta: '4009990001', codigo_referido: 'ad000000-0000-4000-8000-000000000001',
    principal: 0, bolsillos: [], cdts: [], creditos: [], tx: [],
  },
  {
    id: 3, username: 'bloqueado1', password: 'Banco2026', rol: 'CLIENTE', estado: 'BLOQUEADO',
    nombres: 'Mateo', nombre: 'Mateo Ríos Salazar', cedula: '1098765432', correo: 'mateo.rios@correo.co',
    telefono: '3157654321', numero_cuenta: '4005006007', codigo_referido: 'b1000000-0000-4000-8000-000000000003',
    principal: 120000, bolsillos: [], cdts: [], creditos: [], tx: [],
  },
  {
    id: 4, username: 'cgomez12', password: 'Banco2026', rol: 'CLIENTE', estado: 'ACTIVO',
    nombres: 'Camila', nombre: 'Camila Rodríguez Peña', cedula: '1012345678', correo: 'camila.rodriguez@correo.co',
    telefono: '3209876543', numero_cuenta: '4003004005', codigo_referido: 'c4000000-0000-4000-8000-000000000004',
    principal: 1800000, bolsillos: [{ id: 41, nombre: 'Ahorro', saldo: 300000 }], cdts: [], creditos: [], tx: [],
  },
];

const extraDestinatarios = {
  '4007008009': 'Andrés Felipe Mora', '4008009001': 'Laura Valentina Ospina', '4001112223': 'Santiago Gómez Ruiz',
};

const productosCredito = [
  { id: 1, nombre: 'Libre inversión', descripcion: 'Dinero para lo que necesites, con cuotas fijas.', tasa: 0.018, monto_min: 1000000, monto_max: 30000000, plazo_min: 6, plazo_max: 60 },
  { id: 2, nombre: 'Vivienda', descripcion: 'Financia tu casa o apartamento a largo plazo.', tasa: 0.011, monto_min: 20000000, monto_max: 300000000, plazo_min: 60, plazo_max: 240 },
  { id: 3, nombre: 'Vehículo', descripcion: 'Estrena carro o moto con tasas competitivas.', tasa: 0.0145, monto_min: 5000000, monto_max: 90000000, plazo_min: 12, plazo_max: 72 },
  { id: 4, nombre: 'Educativo', descripcion: 'Invierte en tu formación y la de tu familia.', tasa: 0.012, monto_min: 500000, monto_max: 40000000, plazo_min: 6, plazo_max: 84 },
];
const definicionesCdt = [
  { id: 1, nombre: 'CDT 90 días', tasa: 0.0925, plazo_dias: 90, monto_min: 500000 },
  { id: 2, nombre: 'CDT 180 días', tasa: 0.10, plazo_dias: 180, monto_min: 1000000 },
  { id: 3, nombre: 'CDT 360 días', tasa: 0.1075, plazo_dias: 360, monto_min: 2000000 },
];
let mora = 0.025;
const reloj = { usar_fecha_real: true, fecha_sistema: hoy() };
const fechaActual = () => (reloj.usar_fecha_real ? hoy() : reloj.fecha_sistema);

let caida = false;
const sesiones = new Map(); // sid -> user id

// ---------- esquema ----------
const col = (nombre, tipo, o = {}) => ({ nombre, tipo, ...o });
const PK = { llave: true, no_nulo: true };
const esquema = {
  tablas: [
    { nombre: 'usuario', columnas: [col('id', 'bigint', PK), col('username', 'text', { unico: true, no_nulo: true }), col('password_hash', 'text', { no_nulo: true }), col('nombres', 'text', { no_nulo: true }), col('cedula', 'text', { unico: true, no_nulo: true }), col('correo', 'text', { unico: true, no_nulo: true }), col('rol', 'text', { no_nulo: true }), col('estado', 'text', { no_nulo: true }), col('referido_por', 'bigint')], fks: [{ columna: 'referido_por', tabla_destino: 'usuario', columna_destino: 'id' }] },
    { nombre: 'cuenta', columnas: [col('id', 'bigint', PK), col('usuario_id', 'bigint', { unico: true, no_nulo: true }), col('numero', 'text', { unico: true, no_nulo: true }), col('saldo', 'numeric', { no_nulo: true })], fks: [{ columna: 'usuario_id', tabla_destino: 'usuario', columna_destino: 'id' }] },
    { nombre: 'bolsillo', columnas: [col('id', 'bigint', PK), col('cuenta_id', 'bigint', { no_nulo: true }), col('nombre', 'text', { no_nulo: true }), col('saldo', 'numeric', { no_nulo: true })], fks: [{ columna: 'cuenta_id', tabla_destino: 'cuenta', columna_destino: 'id' }] },
    { nombre: 'cdt_definicion', columnas: [col('id', 'bigint', PK), col('nombre', 'text', { no_nulo: true }), col('tasa', 'numeric', { no_nulo: true }), col('plazo_dias', 'int', { no_nulo: true }), col('monto_min', 'numeric', { no_nulo: true })], fks: [] },
    { nombre: 'cdt', columnas: [col('id', 'bigint', PK), col('cuenta_id', 'bigint', { no_nulo: true }), col('definicion_id', 'bigint', { no_nulo: true }), col('monto', 'numeric', { no_nulo: true }), col('fecha_apertura', 'date', { no_nulo: true })], fks: [{ columna: 'cuenta_id', tabla_destino: 'cuenta', columna_destino: 'id' }, { columna: 'definicion_id', tabla_destino: 'cdt_definicion', columna_destino: 'id' }] },
    { nombre: 'credito_producto', columnas: [col('id', 'bigint', PK), col('nombre', 'text', { unico: true, no_nulo: true }), col('tasa', 'numeric', { no_nulo: true }), col('monto_min', 'numeric'), col('monto_max', 'numeric')], fks: [] },
    { nombre: 'credito', columnas: [col('id', 'bigint', PK), col('cuenta_id', 'bigint', { no_nulo: true }), col('producto_id', 'bigint', { no_nulo: true }), col('monto', 'numeric', { no_nulo: true }), col('plazo', 'int', { no_nulo: true })], fks: [{ columna: 'cuenta_id', tabla_destino: 'cuenta', columna_destino: 'id' }, { columna: 'producto_id', tabla_destino: 'credito_producto', columna_destino: 'id' }] },
    { nombre: 'cuota', columnas: [col('id', 'bigint', PK), col('credito_id', 'bigint', { no_nulo: true }), col('numero', 'int', { no_nulo: true }), col('valor', 'numeric', { no_nulo: true }), col('pagada', 'boolean', { no_nulo: true })], fks: [{ columna: 'credito_id', tabla_destino: 'credito', columna_destino: 'id' }] },
    { nombre: 'transaccion', columnas: [col('id', 'bigint', PK), col('cuenta_origen', 'bigint'), col('cuenta_destino', 'bigint'), col('monto', 'numeric', { no_nulo: true }), col('fecha', 'timestamptz', { no_nulo: true }), col('nota', 'text')], fks: [{ columna: 'cuenta_origen', tabla_destino: 'cuenta', columna_destino: 'id' }, { columna: 'cuenta_destino', tabla_destino: 'cuenta', columna_destino: 'id' }] },
    { nombre: 'reloj', columnas: [col('id', 'int', PK), col('usar_fecha_real', 'boolean', { no_nulo: true }), col('fecha_sistema', 'date')], fks: [] },
    { nombre: 'parametro', columnas: [col('clave', 'text', PK), col('valor', 'text', { no_nulo: true })], fks: [] },
  ],
};

function filasTabla(nombre) {
  const cuentaId = (u) => u.id * 10;
  switch (nombre) {
    case 'usuario': return usuarios.map((u) => ({ id: u.id, username: u.username, password_hash: '••••', nombres: u.nombres, cedula: u.cedula, correo: u.correo, rol: u.rol, estado: u.estado, referido_por: u.id === 4 ? 1 : null }));
    case 'cuenta': return usuarios.map((u) => ({ id: cuentaId(u), usuario_id: u.id, numero: u.numero_cuenta, saldo: u.principal }));
    case 'bolsillo': return usuarios.flatMap((u) => u.bolsillos.map((b) => ({ id: b.id, cuenta_id: cuentaId(u), nombre: b.nombre, saldo: b.saldo })));
    case 'cdt_definicion': return definicionesCdt;
    case 'cdt': return usuarios.flatMap((u) => u.cdts.map((c) => ({ id: c.id, cuenta_id: cuentaId(u), definicion_id: c.definicion_id, monto: c.monto, fecha_apertura: fechaDesde(c.abierto) })));
    case 'credito_producto': return productosCredito.map(({ id, nombre, tasa, monto_min, monto_max }) => ({ id, nombre, tasa, monto_min, monto_max }));
    case 'credito': return usuarios.flatMap((u) => u.creditos.map((c) => ({ id: c.id, cuenta_id: cuentaId(u), producto_id: c.producto_id, monto: c.monto, plazo: c.plazo })));
    case 'cuota': return usuarios.flatMap((u) => u.creditos.flatMap((c) => Array.from({ length: Math.min(c.plazo, 24) }, (_, i) => ({ id: c.id * 100 + i + 1, credito_id: c.id, numero: i + 1, valor: cuotaMensual(c.monto, c.tasa, c.plazo), pagada: i < c.cuotas_pagadas }))));
    case 'transaccion': return usuarios.flatMap((u) => u.tx.map((t) => ({ id: t.id, cuenta_origen: t.tipo === 'envio' ? cuentaId(u) : null, cuenta_destino: t.tipo === 'recibo' ? cuentaId(u) : null, monto: t.monto, fecha: t.fecha, nota: t.nota ?? null })));
    case 'reloj': return [{ id: 1, usar_fecha_real: reloj.usar_fecha_real, fecha_sistema: reloj.fecha_sistema }];
    case 'parametro': return [{ clave: 'tasa_mora', valor: String(mora) }, { clave: 'bono_referido', valor: '50000' }];
    default: return null;
  }
}
const fechaDesde = (dias) => new Date(Date.now() + dias * 86400000).toISOString().slice(0, 10);

// ---------- cálculos (el mock hace de backend) ----------
function cuotaMensual(monto, tasa, plazo) {
  return redondea((monto * tasa) / (1 - Math.pow(1 + tasa, -plazo)));
}
const totalDe = (u) => u.principal + u.bolsillos.reduce((s, b) => s + b.saldo, 0);
const diasTrans = (c) => Math.max(0, Math.round((new Date(fechaActual()) - new Date(fechaDesde(c.abierto))) / 86400000));
const generadoCdt = (monto, tasa, dias) => redondea(monto * tasa * (dias / 365));
const cdtActivos = (u) => u.cdts.filter((c) => c.activo);
const interesMes = (c) => redondea(c.saldo * c.tasa);

function registrarTx(u, tipo, monto, contraparte, nota) {
  u.tx.unshift({ id: nuevoId(), tipo, monto, fecha: new Date().toISOString(), contraparte, ...(nota ? { nota } : {}) });
}

// ---------- HTTP ----------
class Neg extends Error { constructor(m, status = 400) { super(m); this.status = status; } }
const neg = (m) => new Neg(m);

function leerCuerpo(req) {
  return new Promise((ok) => {
    let s = '';
    req.on('data', (c) => (s += c));
    req.on('end', () => { try { ok(s ? JSON.parse(s) : {}); } catch { ok({}); } });
  });
}
function enviar(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', ...headers });
  res.end(JSON.stringify(body));
}
const sidDe = (req) => /(?:^|;\s*)sid=([^;]+)/.exec(req.headers.cookie ?? '')?.[1];
const usuarioDe = (req) => usuarios.find((u) => u.id === sesiones.get(sidDe(req)));
function requiere(req, rol) {
  const u = usuarioDe(req);
  if (!u) throw new Neg('No autenticado', 401);
  if (rol && u.rol !== rol) throw new Neg('Sin permiso', 403);
  return u;
}
const num = (v, nombre = 'Monto') => {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) throw neg(`${nombre} inválido`);
  return n;
};
const porId = (lista, id) => lista.find((x) => String(x.id) === String(id));

async function ruta(req, res, url, metodo, p, body) {
  const q = url.searchParams;
  let m;
  // ----- públicas -----
  if (metodo === 'GET' && p === '/creditos/productos') return productosCredito;
  if (metodo === 'POST' && p === '/auth/login') {
    const u = usuarios.find((x) => x.username === body.username && x.password === body.password);
    if (!u) throw neg('Credenciales inválidas');
    if (u.estado === 'BLOQUEADO') throw neg('Tu cuenta ha sido restringida, contacte con el banco para desbloquearla');
    const sid = randomUUID();
    sesiones.set(sid, u.id);
    res.setHeader('Set-Cookie', `sid=${sid}; HttpOnly; Path=/; SameSite=Lax`);
    return { username: u.username, rol: u.rol };
  }
  if (metodo === 'POST' && p === '/auth/registro') {
    for (const k of ['nombres', 'apellidos', 'cedula', 'correo', 'password']) if (!body[k]) throw neg(`Falta el campo ${k}`);
    if (usuarios.some((x) => x.cedula === body.cedula)) throw neg('Ya existe un usuario con esa cédula');
    const username = `${body.nombres[0]}${body.apellidos.split(' ')[0]}${Math.floor(100 + Math.random() * 900)}`.toLowerCase().normalize('NFD').replace(/[^a-z0-9]/g, '');
    const id = nuevoId();
    usuarios.push({
      id, username, password: body.password, rol: 'CLIENTE', estado: 'ACTIVO', nombres: body.nombres,
      nombre: `${body.nombres} ${body.apellidos}`, cedula: body.cedula, correo: body.correo, telefono: body.telefono ?? '',
      numero_cuenta: String(4100000000 + id), codigo_referido: randomUUID(), principal: 0, bolsillos: [], cdts: [], creditos: [], tx: [],
    });
    return { username };
  }
  if (metodo === 'POST' && p === '/auth/logout') { sesiones.delete(sidDe(req)); res.setHeader('Set-Cookie', 'sid=; HttpOnly; Path=/; Max-Age=0'); return {}; }
  if (metodo === 'GET' && p === '/yo') { const u = requiere(req); return { username: u.username, rol: u.rol }; }

  // ----- cliente -----
  if (metodo === 'GET' && p === '/dashboard') {
    const u = requiere(req);
    const act = cdtActivos(u);
    return {
      nombre: u.nombres, balance_total: totalDe(u), transacciones: u.tx.slice(0, 8),
      cdts: { activos: act.length, generado: act.reduce((s, c) => s + generadoCdt(c.monto, c.tasa, diasTrans(c)), 0) },
      creditos: { cuota_por_pagar: u.creditos.reduce((s, c) => s + cuotaMensual(c.monto, c.tasa, c.plazo), 0), interes_corriendo: u.creditos.reduce((s, c) => s + interesMes(c), 0) },
    };
  }
  if (metodo === 'GET' && p === '/bolsillos') { const u = requiere(req); return { total: totalDe(u), principal: u.principal, bolsillos: u.bolsillos }; }
  if (metodo === 'POST' && p === '/bolsillos') {
    const u = requiere(req);
    if (!String(body.nombre ?? '').trim()) throw neg('Nombre inválido');
    u.bolsillos.push({ id: nuevoId(), nombre: String(body.nombre).trim(), saldo: 0 });
    return {};
  }
  if (metodo === 'POST' && (m = /^\/bolsillos\/([^/]+)\/(ingresar|retirar|mover)$/.exec(p))) {
    const u = requiere(req);
    const b = porId(u.bolsillos, m[1]);
    if (!b) throw neg('Bolsillo no encontrado');
    const monto = num(body.monto);
    if (m[2] === 'ingresar') {
      if (u.principal < monto) throw neg('Saldo insuficiente en la cuenta principal');
      u.principal -= monto; b.saldo += monto;
    } else if (m[2] === 'retirar') {
      if (b.saldo < monto) throw neg('Saldo insuficiente en el bolsillo');
      b.saldo -= monto; u.principal += monto;
    } else {
      const d = porId(u.bolsillos, body.destino_id);
      if (!d) throw neg('Bolsillo destino no encontrado');
      if (b.saldo < monto) throw neg('Saldo insuficiente en el bolsillo');
      b.saldo -= monto; d.saldo += monto;
    }
    return {};
  }
  if (metodo === 'GET' && p === '/transacciones') { const u = requiere(req); return u.tx.slice(0, Number(q.get('limite') ?? 50)); }
  if (metodo === 'GET' && p === '/perfil') { const u = requiere(req); return { username: u.username, numero_cuenta: u.numero_cuenta, codigo_referido: u.codigo_referido }; }
  if (metodo === 'GET' && (m = /^\/destinatario\/([^/]+)$/.exec(p))) {
    requiere(req);
    const n = decodeURIComponent(m[1]);
    const d = usuarios.find((x) => x.numero_cuenta === n);
    const nombre = d?.nombre ?? extraDestinatarios[n];
    if (!nombre) throw neg('Cuenta no encontrada');
    return { nombre };
  }
  if (metodo === 'POST' && p === '/envios') {
    const u = requiere(req);
    const monto = num(body.monto);
    const dest = usuarios.find((x) => x.numero_cuenta === body.numero_destino);
    const nombre = dest?.nombre ?? extraDestinatarios[body.numero_destino];
    if (!nombre) throw neg('Cuenta no encontrada');
    if (dest === u) throw neg('No puedes enviarte dinero a ti mismo');
    const origen = body.bolsillo_origen ? porId(u.bolsillos, body.bolsillo_origen) : null;
    if (body.bolsillo_origen && !origen) throw neg('Bolsillo no encontrado');
    const disponible = origen ? origen.saldo : u.principal;
    if (disponible < monto) throw neg('Saldo insuficiente');
    if (origen) origen.saldo -= monto; else u.principal -= monto;
    registrarTx(u, 'envio', monto, nombre, body.nota);
    if (dest) { dest.principal += monto; registrarTx(dest, 'recibo', monto, u.nombre, body.nota); }
    return {};
  }

  // ----- créditos -----
  if (metodo === 'GET' && p === '/creditos/mis-creditos') {
    const u = requiere(req);
    return u.creditos.map((c) => ({ id: c.id, producto: c.producto, cuotas_pagadas: c.cuotas_pagadas, cuotas_faltantes: c.plazo - c.cuotas_pagadas, interes_mes: interesMes(c), saldo: c.saldo }));
  }
  const validaCredito = () => {
    const prod = porId(productosCredito, body.producto_id);
    if (!prod) throw neg('Producto no encontrado');
    const monto = num(body.monto), plazo = num(body.plazo, 'Plazo');
    if (monto < prod.monto_min || monto > prod.monto_max) throw neg(`El monto debe estar entre ${prod.monto_min} y ${prod.monto_max}`);
    if (plazo < prod.plazo_min || plazo > prod.plazo_max) throw neg(`El plazo debe estar entre ${prod.plazo_min} y ${prod.plazo_max} meses`);
    return { prod, monto, plazo };
  };
  if (metodo === 'POST' && p === '/creditos/simular') {
    requiere(req);
    const { prod, monto, plazo } = validaCredito();
    const cuota = cuotaMensual(monto, prod.tasa, plazo);
    return { cuota_mensual: cuota, total_a_pagar: cuota * plazo, intereses_totales: cuota * plazo - monto };
  }
  if (metodo === 'POST' && p === '/creditos') {
    const u = requiere(req);
    const { prod, monto, plazo } = validaCredito();
    u.creditos.push({ id: nuevoId(), producto_id: prod.id, producto: prod.nombre, monto, plazo, tasa: prod.tasa, cuotas_pagadas: 0, saldo: monto });
    u.principal += monto;
    registrarTx(u, 'recibo', monto, `Desembolso crédito ${prod.nombre}`);
    return {};
  }
  if (metodo === 'POST' && (m = /^\/creditos\/([^/]+)\/abono$/.exec(p))) {
    const u = requiere(req);
    const c = porId(u.creditos, m[1]);
    if (!c) throw neg('Crédito no encontrado');
    const monto = num(body.monto);
    if (monto > u.principal) throw neg('Saldo insuficiente');
    if (monto > c.saldo) throw neg('El abono supera el saldo del crédito');
    u.principal -= monto; c.saldo -= monto;
    registrarTx(u, 'envio', monto, `Abono a capital ${c.producto}`);
    return {};
  }

  // ----- CDTs -----
  if (metodo === 'GET' && p === '/cdts/definiciones') { requiere(req); return definicionesCdt; }
  if (metodo === 'GET' && p === '/cdts') {
    const u = requiere(req);
    return cdtActivos(u).map((c) => {
      const cierre = new Date(fechaDesde(c.abierto)); cierre.setDate(cierre.getDate() + c.plazo_dias);
      const restan = Math.max(0, Math.round((cierre - new Date(fechaActual())) / 86400000));
      return { id: c.id, monto: c.monto, generado_hasta_hoy: generadoCdt(c.monto, c.tasa, diasTrans(c)), tiempo_restante: `${restan} días`, fecha_cierre: cierre.toISOString() };
    });
  }
  const validaCdt = () => {
    const d = porId(definicionesCdt, body.definicion_id);
    if (!d) throw neg('Definición no encontrada');
    const monto = num(body.monto);
    if (monto < d.monto_min) throw neg(`El monto mínimo es ${d.monto_min}`);
    return { d, monto };
  };
  if (metodo === 'POST' && p === '/cdts/simular') {
    requiere(req);
    const { d, monto } = validaCdt();
    return { generado_mes: generadoCdt(monto, d.tasa, 30), generado_dia: generadoCdt(monto, d.tasa, 1), generado_vencimiento: generadoCdt(monto, d.tasa, d.plazo_dias) };
  }
  if (metodo === 'POST' && p === '/cdts') {
    const u = requiere(req);
    const { d, monto } = validaCdt();
    if (u.principal < monto) throw neg('Saldo insuficiente');
    u.principal -= monto;
    u.cdts.push({ id: nuevoId(), definicion_id: d.id, monto, tasa: d.tasa, plazo_dias: d.plazo_dias, abierto: Math.round((new Date(fechaActual()) - Date.now()) / 86400000), activo: true });
    return {};
  }

  // ----- admin -----
  if (p.startsWith('/admin/')) {
    requiere(req, 'ADMIN');
    const fila = (u) => ({ id: u.id, username: u.username, nombre: u.nombre, cedula: u.cedula, correo: u.correo, numero_cuenta: u.numero_cuenta, estado: u.estado });
    if (metodo === 'GET' && p === '/admin/usuarios') {
      const b = (q.get('busqueda') ?? '').trim().toLowerCase();
      return usuarios.filter((u) => u.rol === 'CLIENTE' && (!b || [u.nombre, u.cedula, u.correo, u.numero_cuenta, u.username].some((v) => v.toLowerCase().includes(b)))).map(fila);
    }
    if ((m = /^\/admin\/usuarios\/([^/]+)(?:\/(bloquear|desbloquear))?$/.exec(p))) {
      const u = porId(usuarios, m[1]);
      if (!u) throw neg('Usuario no encontrado');
      if (metodo === 'GET' && !m[2]) {
        return { ...fila(u), balance: { total: totalDe(u), principal: u.principal, bolsillos: u.bolsillos, cdts: cdtActivos(u).map((c) => ({ id: c.id, monto: c.monto })), creditos: u.creditos.map((c) => ({ id: c.id, producto: c.producto, saldo: c.saldo })) }, historial: u.tx };
      }
      if (metodo === 'POST' && m[2]) { u.estado = m[2] === 'bloquear' ? 'BLOQUEADO' : 'ACTIVO'; return {}; }
      if (metodo === 'DELETE' && !m[2]) { usuarios.splice(usuarios.indexOf(u), 1); return {}; }
    }
    if (metodo === 'POST' && p === '/admin/balance') {
      const u = porId(usuarios, body.usuario_id) ?? usuarios.find((x) => x.username === body.usuario_id);
      if (!u) throw neg('Usuario no encontrado');
      const monto = Number(body.monto);
      if (!Number.isFinite(monto) || monto === 0) throw neg('Monto inválido');
      u.principal += monto;
      registrarTx(u, monto > 0 ? 'recibo' : 'envio', Math.abs(monto), 'Banco Digital', body.nota);
      return {};
    }
    if (metodo === 'GET' && p === '/admin/reloj') return { ...reloj, fecha_actual: fechaActual() };
    if (metodo === 'PUT' && p === '/admin/reloj') {
      if (!body.usar_fecha_real) {
        if (!body.fecha_sistema) throw neg('Fecha inválida');
        if (body.fecha_sistema < fechaActual()) throw neg('El reloj solo puede adelantarse');
      }
      reloj.usar_fecha_real = !!body.usar_fecha_real;
      if (body.fecha_sistema) reloj.fecha_sistema = body.fecha_sistema;
      return {};
    }
    if (metodo === 'GET' && p === '/admin/tasas') {
      return { cdts: definicionesCdt.map(({ id, nombre, tasa }) => ({ id, nombre, tasa })), creditos: productosCredito.map(({ id, nombre, tasa }) => ({ id, nombre, tasa })), mora };
    }
    if (metodo === 'PUT' && p === '/admin/tasas') {
      const t = (v) => { const n = Number(v); if (!Number.isFinite(n) || n < 0) throw neg('Tasa inválida'); return n; };
      for (const [id, v] of Object.entries(body.cdts ?? {})) { const d = porId(definicionesCdt, id); if (d) d.tasa = t(v); }
      for (const [id, v] of Object.entries(body.creditos ?? {})) { const d = porId(productosCredito, id); if (d) d.tasa = t(v); }
      if (body.mora !== undefined) mora = t(body.mora);
      return {};
    }
    if (metodo === 'GET' && p === '/admin/esquema') return esquema;
    if (metodo === 'GET' && (m = /^\/admin\/tabla\/([^/]+)$/.exec(p))) {
      const nombre = decodeURIComponent(m[1]);
      const t = esquema.tablas.find((x) => x.nombre === nombre);
      if (!t) throw neg('Tabla no encontrada');
      const filas = filasTabla(nombre), tam = 10;
      const total = Math.max(1, Math.ceil(filas.length / tam));
      const pagina = Math.min(Math.max(1, Number(q.get('pagina')) || 1), total);
      return { columnas: t.columnas.map((c) => c.nombre), filas: filas.slice((pagina - 1) * tam, pagina * tam), pagina, total_paginas: total };
    }
  }
  throw new Neg('Ruta no encontrada', 404);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const metodo = req.method;
  try {
    if (url.pathname === '/__mock/estado' && metodo === 'GET') return enviar(res, 200, { caida });
    if (url.pathname === '/__mock/caida' && metodo === 'POST') { caida = !caida; console.log(`BD caída: ${caida ? 'ACTIVADA' : 'desactivada'}`); return enviar(res, 200, { caida }); }
    if (!url.pathname.startsWith('/api/')) return enviar(res, 404, { error: 'Ruta no encontrada' });
    if (caida) return enviar(res, 503, { error: 'sin_conexion' });
    const body = metodo === 'GET' || metodo === 'DELETE' ? {} : await leerCuerpo(req);
    const r = await ruta(req, res, url, metodo, url.pathname.slice(4), body);
    enviar(res, 200, r);
  } catch (e) {
    if (e instanceof Neg) return enviar(res, e.status, { error: e.message });
    console.error(e);
    enviar(res, 500, { error: 'Error interno del mock' });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Mock del Banco Digital en http://127.0.0.1:${PORT}  (solo desarrollo)`);
  console.log('Usuarios: jperez483 (cliente), admin1 (admin), bloqueado1 (bloqueado). Clave: Banco2026');
  console.log(`Simular caída de la BD (alterna):  curl -X POST localhost:${PORT}/__mock/caida`);
  console.log(`Ver estado:                        curl localhost:${PORT}/__mock/estado`);
});
