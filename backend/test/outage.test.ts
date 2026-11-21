import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { execSync } from 'node:child_process';
import { crearDb } from '../src/db';
import { hacerApp } from './helpers';

describe('apagón de la BD', () => {
  it('con la BD inalcanzable: 503 repetido y el proceso sigue vivo', async () => {
    const app = hacerApp(crearDb('postgres://u:p@127.0.0.1:1/banco')); // puerto cerrado
    for (let i = 0; i < 3; i++) {
      const r = await request(app).get('/api/creditos/productos');
      expect(r.status).toBe(503); expect(r.body).toEqual({ error: 'sin_conexion' });
    }
  });
  it('sin cookie, las rutas de cliente responden 401 aunque la BD esté caída', async () => {
    const app = hacerApp(crearDb('postgres://u:p@127.0.0.1:1/banco'));
    expect((await request(app).get('/api/dashboard')).status).toBe(401);
  });
});

// FIX 9 (necesita docker compose con db + DATABASE_URL real): RUN_OUTAGE=1 npx vitest run outage
describe.skipIf(!process.env.RUN_OUTAGE)('stop/start db real', () => {
  it('503 al parar la BD y vuelve a 200 al iniciarla, sin reiniciar el backend', async () => {
    const app = hacerApp(crearDb());
    const url = '/api/creditos/productos';
    expect((await request(app).get(url)).status).toBe(200);
    execSync('docker compose stop db', { cwd: '..' });
    try { expect((await request(app).get(url)).status).toBe(503); }
    finally { execSync('docker compose start db', { cwd: '..' }); }
    let s = 0; for (let i = 0; i < 20 && s !== 200; i++) { await new Promise((r) => setTimeout(r, 1000)); s = (await request(app).get(url)).status; }
    expect(s).toBe(200);
  }, 60000);
});
