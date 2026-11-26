import { Router } from 'express';
import type { Db } from '../db';
import { requireAdmin, requireSession } from '../session';

const wrap = (f: (req: any, res: any) => Promise<unknown>) => (req: any, res: any, next: any) => f(req, res).catch(next);

/** p_admin_id siempre es el de la sesión; la BD vuelve a verificar el rol ('Acceso denegado'). */
export function adminRoutes(db: Db, secret: string) {
  const r = Router();
  r.use(requireSession(db, secret), requireAdmin);
  const a = (req: any) => req.user.id;
  const b = (req: any) => req.body ?? {};
  const json = async (fn: string, args: unknown[]) => (await db.call(fn, args))[0]?.[fn];
  const hecho = (fn: string, args: (req: any) => unknown[]) =>
    wrap(async (req, res) => { await db.call(fn, args(req)); res.json({}); });

  r.get('/usuarios', wrap(async (q, res) => res.json(await db.call('admin_listar_usuarios', [a(q), q.query.busqueda ?? '']))));
  r.get('/usuarios/:id', wrap(async (q, res) => res.json(await json('admin_detalle_usuario', [a(q), q.params.id]))));
  r.post('/usuarios/:id/bloquear', hecho('admin_bloquear', (q) => [a(q), q.params.id]));
  r.post('/usuarios/:id/desbloquear', hecho('admin_desbloquear', (q) => [a(q), q.params.id]));
  r.delete('/usuarios/:id', hecho('admin_borrar_usuario', (q) => [a(q), q.params.id]));
  r.post('/balance', hecho('admin_ajustar_balance', (q) => [a(q), b(q).usuario_id, b(q).monto, b(q).nota ?? null]));

  r.get('/reloj', wrap(async (q, res) => res.json(await json('admin_get_reloj', [a(q)]))));
  r.put('/reloj', hecho('admin_set_reloj', (q) => [a(q), b(q).usar_fecha_real, b(q).fecha_sistema ?? null]));

  r.get('/tasas', wrap(async (q, res) => res.json(await json('admin_get_tasas', [a(q)]))));
  r.put('/tasas', wrap(async (q, res) => {
    const x = b(q), id = a(q);
    const calls: [string, unknown[]][] = [
      ...Object.entries(x.cdts ?? {}).map(([k, v]): [string, unknown[]] => ['admin_set_tasa_cdt', [id, k, v]]),
      ...Object.entries(x.creditos ?? {}).map(([k, v]): [string, unknown[]] => ['admin_set_tasa_credito', [id, k, v]]),
      ...(x.mora !== undefined ? [['admin_set_tasa_mora', [id, x.mora]] as [string, unknown[]]] : []),
    ];
    await db.tx(calls); // atómico: todo o nada
    res.json({});
  }));

  r.get('/esquema', wrap(async (q, res) => res.json(await json('admin_esquema', [a(q)]))));
  r.get('/tabla/:nombre', wrap(async (q, res) =>
    res.json(await json('admin_tabla', [a(q), q.params.nombre, q.query.pagina ?? 1]))));
  return r;
}
