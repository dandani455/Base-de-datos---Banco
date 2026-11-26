import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { ADMIN, UID, dbConUsuarios, hacerApp, login, negocio } from './helpers';

describe('admin', () => {
  it('cliente en /api/admin/* → 403 y sin tocar funciones admin', async () => {
    const { db } = dbConUsuarios(); const app = hacerApp(db); const c = await login(app, request);
    expect((await request(app).get('/api/admin/usuarios').set('Cookie', c)).status).toBe(403);
    expect((db as any).calls.some((x: any) => x[0].startsWith('admin_'))).toBe(false);
  });
  it('sin cookie → 401', async () => {
    const { db } = dbConUsuarios();
    expect((await request(hacerApp(db)).get('/api/admin/esquema')).status).toBe(401);
  });
  it('admin: p_admin_id sale de la sesión; búsqueda y detalle', async () => {
    const { db } = dbConUsuarios({
      admin_listar_usuarios: () => [{ admin_listar_usuarios: [{ id: UID }] }],
      admin_detalle_usuario: () => [{ admin_detalle_usuario: { id: UID, balance: {} } }],
    });
    const app = hacerApp(db); const c = await login(app, request, 'admin1');
    const l = await request(app).get('/api/admin/usuarios?busqueda=juan').set('Cookie', c);
    expect(l.body).toEqual([{ id: UID }]);
    expect((db as any).calls.find((x: any) => x[0] === 'admin_listar_usuarios')[1]).toEqual([ADMIN, 'juan']);
    expect((await request(app).get(`/api/admin/usuarios/${UID}`).set('Cookie', c)).body.id).toBe(UID);
  });
  it('PUT tasas llama a las 3 funciones set_tasa', async () => {
    const ok = () => [] as any[];
    const { db } = dbConUsuarios({ admin_set_tasa_cdt: ok, admin_set_tasa_credito: ok, admin_set_tasa_mora: ok });
    const app = hacerApp(db); const c = await login(app, request, 'admin1');
    const r = await request(app).put('/api/admin/tasas').set('Cookie', c).send({ cdts: { a: 9 }, creditos: { b: 20 }, mora: 30 });
    expect(r.status).toBe(200);
    expect((db as any).calls.filter((x: any) => x[0].startsWith('admin_set_tasa')).map((x: any) => x[0]))
      .toEqual(['admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora']);
  });
  it('reloj: error de la BD al retroceder pasa tal cual', async () => {
    const { db } = dbConUsuarios({ admin_set_reloj: () => { throw negocio('El reloj no puede retroceder'); } });
    const app = hacerApp(db); const c = await login(app, request, 'admin1');
    const r = await request(app).put('/api/admin/reloj').set('Cookie', c).send({ usar_fecha_real: false, fecha_sistema: '2020-01-01' });
    expect(r.status).toBe(400); expect(r.body.error).toBe('El reloj no puede retroceder');
  });
});
