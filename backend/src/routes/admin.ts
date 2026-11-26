import { Router } from 'express';
import { json, type Db } from '../db';
import { requireAdmin, requireSession } from '../session';

const wrap = (f: (req: any, res: any) => Promise<unknown>) => (req: any, res: any, next: any) => f(req, res).catch(next);

/** p_admin_id siempre es el de la sesión; la BD vuelve a verificar el rol ('Acceso denegado'). */
export function adminRoutes(db: Db, secret: string) {
  const r = Router();
  r.use(requireSession(db, secret), requireAdmin);
  const a = (req: any) => req.user.id;
  const b = (req: any) => req.body ?? {};
  /** Endpoint que llama a `fn` con los argumentos de `args(req)` y responde su jsonb (D3: todas devuelven jsonb). */
  const ep = (fn: string, args: (req: any) => unknown[]) =>
    wrap(async (req, res) => res.json((await json(db, fn, args(req))) ?? {}));

  r.get('/usuarios', wrap(async (q, res) =>
    res.json((await json(db, 'admin_listar_usuarios', [a(q), q.query.busqueda ?? ''])) ?? [])));
  r.get('/usuarios/:id', ep('admin_detalle_usuario', (q) => [a(q), q.params.id]));
  r.post('/usuarios/:id/bloquear', ep('admin_bloquear', (q) => [a(q), q.params.id]));
  r.post('/usuarios/:id/desbloquear', ep('admin_desbloquear', (q) => [a(q), q.params.id]));
  r.delete('/usuarios/:id', ep('admin_borrar_usuario', (q) => [a(q), q.params.id]));
  // usuario_id: la BD acepta uuid, username o número de cuenta
  r.post('/balance', ep('admin_ajustar_balance', (q) => [a(q), b(q).usuario_id, b(q).monto, b(q).nota ?? null]));

  r.get('/reloj', ep('admin_get_reloj', (q) => [a(q)]));
  r.put('/reloj', ep('admin_set_reloj', (q) => [a(q), b(q).usar_fecha_real, b(q).fecha_sistema ?? null]));

  r.get('/tasas', ep('admin_get_tasas', (q) => [a(q)]));
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

  r.get('/esquema', ep('admin_esquema', (q) => [a(q)]));
  // pagina va como TEXTO tal cual llega (la BD normaliza vacío, basura o fuera de rango)
  r.get('/tabla/:nombre', ep('admin_tabla', (q) => [a(q), q.params.nombre, q.query.pagina ?? null]));
  return r;
}
