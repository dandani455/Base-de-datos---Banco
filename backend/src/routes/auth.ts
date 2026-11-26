import { Router } from 'express';
import bcrypt from 'bcryptjs';
import rateLimit from 'express-rate-limit';
import { json, type Db } from '../db';
import { AppError } from '../errors';
import { COOKIE, firmar, leerToken, opcionesCookie, requireSession } from '../session';
import { enviarVerificacion } from '../mail';

export interface AuthCfg { secret: string; rounds: number; cookieSecure: boolean; appUrl: string }
const wrap = (f: (req: any, res: any) => Promise<unknown>) => (req: any, res: any, next: any) => f(req, res).catch(next);
const PASS_OK = (p: unknown): p is string => typeof p === 'string' && p.length >= 8 && /[A-Z]/.test(p) && /\d/.test(p);

export function authRoutes(db: Db, cfg: AuthCfg) {
  const r = Router();
  const dummy = bcrypt.hashSync('dummy-password', cfg.rounds); // iguala tiempos si el usuario no existe
  const limite = (keyGenerator?: (req: any) => string) => rateLimit({
    windowMs: 15 * 60 * 1000, limit: 5, skipSuccessfulRequests: true, standardHeaders: true, legacyHeaders: false,
    ...(keyGenerator ? { keyGenerator } : {}),
    handler: (_req, res) => void res.status(429).json({ error: 'Demasiados intentos, intenta de nuevo más tarde' }),
  });
  const porIp = limite();
  const porUsuario = limite((req) => `u:${String(req.body?.username ?? '').toLowerCase()}`);
  const linkVerificar = (id: string) =>
    `${cfg.appUrl}/verificar?token=${encodeURIComponent(firmar(cfg.secret, { sub: id, p: 'verificar' }, '24h'))}`;

  r.post('/registro', wrap(async (req, res) => {
    const b = req.body ?? {};
    if (!PASS_OK(b.password)) throw new AppError(400, 'La contraseña debe tener mínimo 8 caracteres, una mayúscula y un número');
    const hash = await bcrypt.hash(b.password, cfg.rounds);
    const verif = process.env.RESEND_ENABLED === 'true';
    const u = await json<{ usuario_id: string; username: string }>(db, 'registrar_usuario', [b.nombres, b.apellidos,
      b.cedula, b.correo, b.telefono, b.fecha_nacimiento, hash, b.acepta_politica, b.codigo_referido ?? null, verif]);
    if (verif) await enviarVerificacion(b.correo, linkVerificar(u.usuario_id));
    res.json({ username: u.username }); // el usuario_id no sale del backend
  }));

  r.post('/verificar', wrap(async (req, res) => {
    const t = leerToken(cfg.secret, req.body?.token);
    if (!t?.sub || t.p !== 'verificar') throw new AppError(400, 'Enlace de verificación inválido o vencido');
    await db.call('verificar_correo', [t.sub]);
    res.json({});
  }));

  r.post('/reenviar', requireSession(db, cfg.secret), wrap(async (req, res) => {
    // OJO: vista_perfil hoy NO trae `correo` (ver README): este endpoint no envía nada hasta que la BD lo agregue.
    const p = await json(db, 'vista_perfil', [req.user.id]);
    if (p?.correo) await enviarVerificacion(p.correo, linkVerificar(req.user.id));
    res.json({});
  }));

  r.post('/login', porIp, porUsuario, wrap(async (req, res) => {
    const { username, password } = req.body ?? {};
    const c = typeof username === 'string' && typeof password === 'string'
      ? (await db.call('obtener_credenciales', [username]))[0] : undefined;
    const ok = await bcrypt.compare(typeof password === 'string' ? password : '', c?.password_hash ?? dummy);
    if (!c || !ok) throw new AppError(400, 'Credenciales inválidas');
    await db.call('validar_sesion', [c.usuario_id]); // bloqueado → P0001 con el mensaje exacto
    res.cookie(COOKIE, firmar(cfg.secret, { sub: c.usuario_id }, '8h'), opcionesCookie(cfg.cookieSecure));
    res.json({ username, rol: c.rol });
  }));

  r.post('/logout', (_req, res) => { res.clearCookie(COOKIE, { path: '/' }); res.json({}); });
  return r;
}

export function yoRoute(db: Db, secret: string) {
  const r = Router();
  // validar_sesion (en requireSession) ya trae username y rol; vista_perfil no sirve aquí: el ADMIN no tiene cuenta.
  r.get('/yo', requireSession(db, secret), (req, res) => {
    res.json({ username: req.user!.username, rol: req.user!.rol });
  });
  return r;
}
