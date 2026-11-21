import { Router } from 'express';
import type { Db } from '../db';
import { requireSession } from '../session';

const wrap = (f: (req: any, res: any) => Promise<unknown>) => (req: any, res: any, next: any) => f(req, res).catch(next);

/** Cada handler = UNA llamada a la BD con el usuario de la sesión. Cero lógica de negocio. */
export function clienteRoutes(db: Db, secret: string) {
  const r = Router();
  const json = async (fn: string, args: unknown[]) => (await db.call(fn, args))[0]?.[fn]; // funciones que devuelven jsonb
  const hecho = (fn: string, args: (req: any) => unknown[]) =>
    wrap(async (req, res) => { await db.call(fn, args(req)); res.json({}); });

  // público (landing)
  r.get('/creditos/productos', wrap(async (_q, res) => res.json(await db.call('productos_publicos'))));

  r.use(requireSession(db, secret));
  const u = (req: any) => req.user.id;
  const b = (req: any) => req.body ?? {};

  r.get('/dashboard', wrap(async (q, res) => res.json(await json('vista_dashboard', [u(q)]))));
  r.get('/perfil', wrap(async (q, res) => res.json(await json('vista_perfil', [u(q)]))));
  r.get('/transacciones', wrap(async (q, res) =>
    res.json(await db.call('vista_historial', [u(q), q.query.limite === undefined ? 50 : q.query.limite]))));

  r.get('/bolsillos', wrap(async (q, res) => res.json(await json('vista_balance', [u(q)]))));
  r.post('/bolsillos', wrap(async (q, res) => { await db.call('crear_bolsillo', [u(q), b(q).nombre]); res.json({}); }));
  r.patch('/bolsillos/:id', hecho('renombrar_bolsillo', (q) => [u(q), q.params.id, b(q).nombre]));
  r.post('/bolsillos/:id/ingresar', hecho('mover_a_bolsillo', (q) => [u(q), q.params.id, b(q).monto]));
  r.post('/bolsillos/:id/retirar', hecho('retirar_de_bolsillo', (q) => [u(q), q.params.id, b(q).monto]));
  r.post('/bolsillos/:id/mover', hecho('mover_entre_bolsillos', (q) => [u(q), q.params.id, b(q).destino_id, b(q).monto]));

  r.get('/destinatario/:numero', wrap(async (q, res) =>
    res.json({ nombre: (await db.call('nombre_destinatario', [q.params.numero]))[0]?.nombre_destinatario })));
  r.post('/envios', hecho('hacer_transferencia', (q) => [u(q), b(q).numero_destino, b(q).monto, b(q).nota ?? null, b(q).bolsillo_origen ?? null]));

  r.get('/cdts/definiciones', wrap(async (_q, res) => res.json(await db.call('listar_cdt_definiciones'))));
  r.get('/cdts', wrap(async (q, res) => res.json(await db.call('vista_cdts', [u(q)]))));
  r.post('/cdts/simular', wrap(async (q, res) =>
    res.json((await db.call('simular_cdt', [b(q).definicion_id, b(q).monto]))[0])));
  r.post('/cdts', hecho('crear_cdt', (q) => [u(q), b(q).definicion_id, b(q).monto]));

  r.get('/creditos/mis-creditos', wrap(async (q, res) => res.json(await db.call('vista_creditos', [u(q)]))));
  r.post('/creditos/simular', wrap(async (q, res) => {
    const s = (await db.call('simular_credito', [b(q).producto_id, b(q).monto, b(q).plazo]))[0];
    // solo renombra campos al contrato del front; no calcula nada
    res.json({ cuota_mensual: s?.cuota, total_a_pagar: s?.total_pagar, intereses_totales: s?.intereses_totales });
  }));
  r.post('/creditos', hecho('solicitar_credito', (q) => [u(q), b(q).producto_id, b(q).monto, b(q).plazo]));
  r.post('/creditos/:id/abono', hecho('abonar_credito', (q) => [u(q), q.params.id, b(q).monto]));
  r.post('/creditos/:id/descuento', hecho('activar_descuento_automatico', (q) => [u(q), q.params.id, b(q).activo]));
  r.post('/creditos/:id/pagar-cuota', hecho('pagar_cuota', (q) => [u(q), q.params.id]));
  return r;
}
