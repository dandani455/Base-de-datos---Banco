import bcrypt from 'bcryptjs';
import { createApp } from '../src/app';
import type { Db, Row } from '../src/db';
import { WHITELIST } from '../src/db';

export class PgError extends Error { constructor(public code: string, m: string) { super(m); } }
export const negocio = (m: string) => new PgError('P0001', m);

export type Handler = (args: unknown[]) => Row[] | Promise<Row[]>;
/** BD falsa: cada función de la whitelist es un handler; registra las llamadas. */
export function fakeDb(handlers: Record<string, Handler> = {}) {
  const calls: [string, unknown[]][] = [];
  const db: Db & { calls: typeof calls; handlers: Record<string, Handler> } = {
    calls, handlers,
    async call(fn, args = []) {
      if (!WHITELIST.has(fn)) throw new Error('no permitida ' + fn);
      calls.push([fn, args]);
      const h = handlers[fn]; if (!h) throw new Error('sin handler ' + fn);
      return h(args);
    },
    async tx(cs) { for (const [fn, args] of cs) await db.call(fn, args); },
  };
  return db;
}

export const SECRET = 'test-secret';
export const hacerApp = (db: Db) => createApp(db, { secret: SECRET, rounds: 4 });
export const hash = (p: string) => bcrypt.hashSync(p, 4);
export const UID = '11111111-1111-1111-1111-111111111111';
export const ADMIN = '22222222-2222-2222-2222-222222222222';
export const BLOQ = 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla';

/** BD con un cliente (jperez483/Banco2026) y un admin (admin1). */
export function dbConUsuarios(extra: Record<string, Handler> = {}) {
  const estado: Record<string, string> = { [UID]: 'ACTIVO', [ADMIN]: 'ACTIVO' };
  const rol: Record<string, string> = { [UID]: 'CLIENTE', [ADMIN]: 'ADMIN' };
  const users: Record<string, { id: string }> = { jperez483: { id: UID }, admin1: { id: ADMIN } };
  const db = fakeDb({
    obtener_credenciales: ([u]) => {
      const x = users[u as string];
      return x ? [{ usuario_id: x.id, password_hash: hash('Banco2026'), rol: rol[x.id], estado: estado[x.id] }] : [];
    },
    validar_sesion: ([id]) => {
      if (!(id as string in estado)) return [];
      if (estado[id as string] === 'BLOQUEADO') throw negocio(BLOQ);
      return [{ rol: rol[id as string], estado: estado[id as string] }];
    },
    vista_perfil: ([id]) => [{ vista_perfil: { username: id === ADMIN ? 'admin1' : 'jperez483', numero_cuenta: '4001002003', codigo_referido: 'x' } }],
    ...extra,
  });
  return { db, estado };
}

export async function login(app: any, request: any, username = 'jperez483') {
  const r = await request(app).post('/api/auth/login').send({ username, password: 'Banco2026' });
  return (r.headers['set-cookie'] as unknown as string[]).map((c) => c.split(';')[0]).join('; ');
}
