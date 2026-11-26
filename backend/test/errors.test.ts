import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { fakeDb, hacerApp, negocio, PgError } from './helpers';
import { WHITELIST, crearDb } from '../src/db';

describe('regla de errores', () => {
  const llamar = (err: unknown) => {
    const db = fakeDb({ productos_publicos: () => { throw err; } });
    return request(hacerApp(db)).get('/api/creditos/productos');
  };
  it('P0001 → 400 con el mensaje de la BD', async () => {
    const r = await llamar(negocio('Saldo insuficiente'));
    expect(r.status).toBe(400); expect(r.body).toEqual({ error: 'Saldo insuficiente' });
  });
  it('Recurso no encontrado / Acceso denegado → 403', async () => {
    expect((await llamar(negocio('Recurso no encontrado'))).status).toBe(403);
    expect((await llamar(negocio('Acceso denegado'))).status).toBe(403);
  });
  it.each([
    ['ECONNREFUSED', Object.assign(new Error('refused'), { code: 'ECONNREFUSED' })],
    ['timeout', new Error('timeout exceeded when trying to connect')],
    ['57P01', new PgError('57P01', 'terminating connection')],
  ])('%s → 503 sin_conexion', async (_n, e) => {
    const r = await llamar(e);
    expect(r.status).toBe(503); expect(r.body).toEqual({ error: 'sin_conexion' });
  });
  it('dato mal formado (UUID inválido) → 400, no 503', async () => {
    expect((await llamar(new PgError('22P02', 'invalid input syntax for type uuid'))).status).toBe(400);
  });
  it('JSON roto → 400', async () => {
    const r = await request(hacerApp(fakeDb())).post('/api/auth/login').set('Content-Type', 'application/json').send('{x');
    expect(r.status).toBe(400);
  });
});

describe('db', () => {
  it('rechaza funciones fuera de la whitelist', async () => {
    const db = crearDb('postgres://x:y@127.0.0.1:1/z');
    await expect(db.call('drop_table', [])).rejects.toThrow(/no permitida/);
  });
  it('la whitelist solo contiene identificadores simples', () => {
    for (const f of WHITELIST) expect(f).toMatch(/^[a-z_]+$/);
  });
});
