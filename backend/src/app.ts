import express from 'express';
import cookieParser from 'cookie-parser';
import type { Db } from './db';
import { AppError, errorMiddleware } from './errors';
import { authRoutes, yoRoute } from './routes/auth';
import { clienteRoutes } from './routes/cliente';
import { adminRoutes } from './routes/admin';

export interface AppCfg { secret: string; rounds?: number; cookieSecure?: boolean; appUrl?: string }

export function createApp(db: Db, cfg: AppCfg) {
  const app = express();
  app.set('trust proxy', 1); // detrás de nginx: IP real para el rate limit
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }), cookieParser());
  const api = express.Router();
  api.use('/auth', authRoutes(db, { secret: cfg.secret, rounds: cfg.rounds ?? 10, cookieSecure: cfg.cookieSecure ?? false, appUrl: cfg.appUrl ?? 'http://localhost' }));
  api.use(yoRoute(db, cfg.secret));
  api.use('/admin', adminRoutes(db, cfg.secret));
  api.use(clienteRoutes(db, cfg.secret));
  api.use((_req, _res, next) => next(new AppError(404, 'Ruta no encontrada')));
  app.use('/api', api);
  app.use(errorMiddleware);
  return app;
}
