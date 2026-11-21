import { createApp } from './app';
import { crearDb } from './db';

const secret = process.env.JWT_SECRET;
if (!secret) { console.error('Falta JWT_SECRET'); process.exit(1); }
const app = createApp(crearDb(), {
  secret,
  rounds: Number(process.env.BCRYPT_ROUNDS ?? 10),
  cookieSecure: process.env.COOKIE_SECURE === 'true',
  appUrl: process.env.APP_URL,
});
// La BD caída nunca debe tumbar el proceso.
process.on('unhandledRejection', (e) => console.error('[unhandledRejection]', e));
process.on('uncaughtException', (e) => console.error('[uncaughtException]', e));
app.listen(Number(process.env.PORT ?? 3000), () => console.log('Backend escuchando'));
