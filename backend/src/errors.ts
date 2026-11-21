import type { ErrorRequestHandler } from 'express';

/** Error propio del backend (autenticación, permisos, límites): no es de la BD. */
export class AppError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

/** Errores de negocio de la BD que significan "no es tuyo / no puedes" → 403 (§9). */
const COMO_403 = new Set(['Recurso no encontrado', 'Acceso denegado']);
export const mapNegocio = (msg: string) => (COMO_403.has(msg) ? 403 : 400);

export const errorMiddleware: ErrorRequestHandler = (err, _req, res, _next) => {
  if (err instanceof AppError) return void res.status(err.status).json({ error: err.message });
  if (err?.type === 'entity.parse.failed') return void res.status(400).json({ error: 'JSON inválido' });
  const code: string | undefined = err?.code;
  if (code === 'P0001') return void res.status(mapNegocio(err.message)).json({ error: err.message });
  // Entrada mal formada (p. ej. UUID inválido en la URL): no es una caída de la BD.
  if (code && /^2[23]/.test(code)) return void res.status(400).json({ error: 'Solicitud inválida' });
  // Todo lo demás (conexión rechazada, timeout, pool…) = BD no disponible.
  console.error('[sin_conexion]', code ?? err?.message);
  res.status(503).json({ error: 'sin_conexion' });
};
