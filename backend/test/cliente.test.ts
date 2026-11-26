import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { ADMIN, UID, dbConUsuarios, hacerApp, login, negocio } from './helpers';

const RUTAS: [string, string][] = [
  ['get', '/api/dashboard'], ['get', '/api/perfil'], ['get', '/api/transacciones'], ['get', '/api/bolsillos'],
  ['post', '/api/bolsillos'], ['post', '/api/envios'], ['get', '/api/cdts'], ['get', '/api/cdts/definiciones'],
  ['post', '/api/cdts'], ['post', '/api/creditos'], ['get', '/api/creditos/mis-creditos'], ['get', '/api/destinatario/123'],
];

describe('cliente', () => {
  it.each(RUTAS)('%s %s sin cookie → 401', async (m, url) => {
    const { db } = dbConUsuarios();
    expect((await (request(hacerApp(db)) as any)[m](url)).status).toBe(401);
  });
  it('crédito público no requiere sesión', async () => {
    const { db } = dbConUsuarios({ productos_publicos: () => [{ productos_publicos: [{ id: 'p1', nombre: 'Libre inversión' }] }] });
    const r = await request(hacerApp(db)).get('/api/creditos/productos');
    expect(r.body).toEqual([{ id: 'p1', nombre: 'Libre inversión' }]);
  });
  it('envío: usa el usuario de la SESIÓN aunque el body traiga otro', async () => {
    const { db } = dbConUsuarios({ hacer_transferencia: () => [{ hacer_transferencia: { id: 'tx1' } }] });
    const app = hacerApp(db); const c = await login(app, request);
    const r = await request(app).post('/api/envios').set('Cookie', c)
      .send({ usuario_id: ADMIN, numero_destino: '4003004005', monto: 5000, nota: 'hola' });
    expect(r.status).toBe(200); expect(r.body).toEqual({ id: 'tx1' });
    expect((db as any).calls.find((x: any) => x[0] === 'hacer_transferencia')[1]).toEqual([UID, '4003004005', 5000, 'hola', null]);
  });
  it('monto inválido → 400 con el mensaje de la BD, no del backend', async () => {
    const { db } = dbConUsuarios({ hacer_transferencia: () => { throw negocio('Monto inválido'); } });
    const app = hacerApp(db); const c = await login(app, request);
    const r = await request(app).post('/api/envios').set('Cookie', c).send({ numero_destino: '1', monto: -5 });
    expect(r.status).toBe(400); expect(r.body.error).toBe('Monto inválido');
  });
  it('recurso ajeno → 403', async () => {
    const { db } = dbConUsuarios({ retirar_de_bolsillo: () => { throw negocio('Recurso no encontrado'); } });
    const app = hacerApp(db); const c = await login(app, request);
    const r = await request(app).post('/api/bolsillos/22222222-0000-0000-0000-000000000000/retirar').set('Cookie', c).send({ monto: 1 });
    expect(r.status).toBe(403);
  });
  it('destinatario, dashboard (jsonb) y simulador de crédito con el contrato del front', async () => {
    const { db } = dbConUsuarios({
      nombre_destinatario: () => [{ nombre_destinatario: { nombre: 'Camila Rodríguez' } }],
      vista_dashboard: () => [{ vista_dashboard: { nombre: 'Juan', balance_total: 10 } }],
      simular_credito: () => [{ simular_credito: { cuota_mensual: 100, total_a_pagar: 1200, intereses_totales: 200 } }],
    });
    const app = hacerApp(db); const c = await login(app, request);
    expect((await request(app).get('/api/destinatario/4003004005').set('Cookie', c)).body).toEqual({ nombre: 'Camila Rodríguez' });
    expect((await request(app).get('/api/dashboard').set('Cookie', c)).body).toEqual({ nombre: 'Juan', balance_total: 10 });
    expect((await request(app).post('/api/creditos/simular').set('Cookie', c).send({ producto_id: 'p', monto: 1, plazo: 12 })).body)
      .toEqual({ cuota_mensual: 100, total_a_pagar: 1200, intereses_totales: 200 });
  });
  it('BD caída en ruta autenticada → 503', async () => {
    const { db } = dbConUsuarios({ vista_dashboard: () => { throw Object.assign(new Error('x'), { code: 'ECONNREFUSED' }); } });
    const app = hacerApp(db); const c = await login(app, request);
    const r = await request(app).get('/api/dashboard').set('Cookie', c);
    expect(r.status).toBe(503); expect(r.body).toEqual({ error: 'sin_conexion' });
  });
});
