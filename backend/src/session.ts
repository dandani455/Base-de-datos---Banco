import jwt from 'jsonwebtoken';
import type { NextFunction, Request, Response } from 'express';
import type { Db } from './db';
import { AppError } from './errors';

export const COOKIE = 'sid';
declare global { namespace Express { interface Request { user?: { id: string; rol: string } } } }

export const firmar = (secret: string, payload: object, expiresIn: string) =>
  jwt.sign(payload, secret, { expiresIn } as jwt.SignOptions);

export function leerToken(secret: string, token: unknown): any | null {
  if (typeof token !== 'string') return null;
  try { return jwt.verify(token, secret); } catch { return null; }
}

export const opcionesCookie = (secure: boolean) =>
  ({ httpOnly: true, sameSite: 'lax' as const, secure, path: '/', maxAge: 8 * 3600 * 1000 });

/** Valida el JWT y consulta la BD en CADA petición (rol y estado vivos; bloqueo inmediato). */
export const requireSession = (db: Db, secret: string) =>
  async (req: Request, _res: Response, next: NextFunction) => {
    try {
      const t = leerToken(secret, req.cookies?.[COOKIE]);
      if (!t?.sub || t.p) throw new AppError(401, 'No autenticado');
      const rows = await db.call('validar_sesion', [t.sub]); // lanza P0001 con el mensaje de bloqueo
      if (!rows[0]) throw new AppError(401, 'No autenticado');
      req.user = { id: t.sub, rol: rows[0].rol };
      next();
    } catch (e) { next(e); }
  };

export const requireAdmin = (req: Request, _res: Response, next: NextFunction) =>
  req.user?.rol === 'ADMIN' ? next() : next(new AppError(403, 'Sin permiso'));
