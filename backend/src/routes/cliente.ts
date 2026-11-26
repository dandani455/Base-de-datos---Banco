import { Router } from 'express';
import { json, type Db } from '../db';
import { COOKIE, leerToken, requireSession } from '../session';

const wrap = (f: (req: any, res: any) => Promise<unknown>) => (req: any, res: any, next: any) => f(req, res).catch(next);

/**
 * Cada handler = UNA llamada a la BD con el usuario de la sesión, y devuelve su jsonb tal cual. Cero lógica de negocio.
 * Contrato: docs/db/etapas/10-resumen-para-juan.md (tabla maestra). Ids y montos pasan tal cual llegan: la BD valida.
 */
export function clienteRoutes(db: Db, secret: string) {
  const r = Router();
  /** Endpoint que llama a `fn` con los argumentos de `args(req)` y responde su jsonb. */
  const ep = (fn: string, args: (req: any) => unknown[]) =>
    wrap(async (req, res) => res.json((await json(db, fn, args(req))) ?? {}));

  // Con sesión: topes efectivos del usuario (regla de edad incluida). Sin sesión (landing): topes base.
  r.get('/creditos/productos', wrap(async (req, res) => {
    const t = leerToken(secret, req.cookies?.[COOKIE]);
    const lista = t?.sub && !t.p
      ? await json(db, 'productos_disponibles', [t.sub])
      : await json(db, 'productos_publicos');
    res.json(lista ?? []);
  }));

  r.use(requireSession(db, secret));
  const u = (req: any) => req.user.id;
  const b = (req: any) => req.body ?? {};

  r.get('/dashboard', ep('vista_dashboard', (q) => [u(q)]));
  r.get('/perfil', ep('vista_perfil', (q) => [u(q)]));
  r.get('/transacciones', wrap(async (q, res) => {
    const n = Number.parseInt(String(q.query.limite ?? ''), 10); // no numérico → NULL = 50 (la BD acota a [1, 50])
    res.json((await json(db, 'vista_historial', [u(q), Number.isNaN(n) ? null : n])) ?? []);
  }));

  r.get('/bolsillos', ep('vista_balance', (q) => [u(q)]));
  r.post('/bolsillos', ep('crear_bolsillo', (q) => [u(q), b(q).nombre]));
  r.post('/bolsillos/:id/ingresar', ep('mover_a_bolsillo', (q) => [u(q), q.params.id, b(q).monto]));
  r.post('/bolsillos/:id/retirar', ep('retirar_de_bolsillo', (q) => [u(q), q.params.id, b(q).monto]));
  r.post('/bolsillos/:id/mover', ep('mover_entre_bolsillos', (q) => [u(q), q.params.id, b(q).destino_id, b(q).monto]));

  r.get('/destinatario/:numero', ep('nombre_destinatario', (q) => [u(q), q.params.numero]));
  r.post('/envios', ep('hacer_transferencia', (q) => [u(q), b(q).numero_destino, b(q).monto, b(q).nota ?? null, b(q).bolsillo_origen ?? null]));

  r.get('/cdts/definiciones', ep('listar_cdt_definiciones', (q) => [u(q)]));
  r.get('/cdts', ep('vista_cdts', (q) => [u(q)]));
  r.post('/cdts/simular', ep('simular_cdt', (q) => [u(q), b(q).definicion_id, b(q).monto]));
  r.post('/cdts', ep('crear_cdt', (q) => [u(q), b(q).definicion_id, b(q).monto]));

  r.get('/creditos/mis-creditos', ep('vista_creditos', (q) => [u(q)]));
  r.post('/creditos/simular', ep('simular_credito', (q) => [u(q), b(q).producto_id, b(q).monto, b(q).plazo]));
  r.post('/creditos', ep('solicitar_credito', (q) => [u(q), b(q).producto_id, b(q).monto, b(q).plazo]));
  r.post('/creditos/:id/abono', ep('abonar_credito', (q) => [u(q), q.params.id, b(q).monto]));
  r.post('/creditos/:id/descuento', ep('activar_descuento_automatico', (q) => [u(q), q.params.id, b(q).activo]));
  // `numero` (cuotas_pagadas + 1) es opcional y evita cobrar dos cuotas por un doble clic.
  r.post('/creditos/:id/pagar-cuota', ep('pagar_cuota', (q) => [u(q), q.params.id, b(q).numero ?? null]));
  return r;
}
