import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { ADMIN, UID, dbConUsuarios, hacerApp, login } from './helpers';

/** Forma real de la BD terminada (E10–E14): todo jsonb, p_usuario_id / p_admin_id primero. */
const llamada = (db: any, fn: string) => db.calls.find((x: any) => x[0] === fn)?.[1];

describe('contrato con la BD terminada', () => {
  it('/creditos/productos: con sesión usa productos_disponibles (topes del usuario); sin sesión, productos_publicos', async () => {
    const { db } = dbConUsuarios({
      productos_publicos: () => [{ productos_publicos: [{ id: 'base' }] }],
      productos_disponibles: () => [{ productos_disponibles: [{ id: 'mio' }] }],
    });
    const app = hacerApp(db);
    expect((await request(app).get('/api/creditos/productos')).body).toEqual([{ id: 'base' }]);
    const c = await login(app, request);
    expect((await request(app).get('/api/creditos/productos').set('Cookie', c)).body).toEqual([{ id: 'mio' }]);
    expect(llamada(db, 'productos_disponibles')).toEqual([UID]);
  });
  it('/yo del ADMIN (sin cuenta) sale de validar_sesion, sin llamar a vista_perfil', async () => {
    const { db } = dbConUsuarios(); const app = hacerApp(db); const c = await login(app, request, 'admin1');
    const r = await request(app).get('/api/yo').set('Cookie', c);
    expect(r.body).toEqual({ username: 'admin1', rol: 'ADMIN' });
    expect(llamada(db, 'vista_perfil')).toBeUndefined();
  });
  it('listas jsonb llegan desenvueltas (historial, cdts, créditos, definiciones)', async () => {
    const { db } = dbConUsuarios({
      vista_historial: () => [{ vista_historial: [{ id: 't1' }] }],
      vista_cdts: () => [{ vista_cdts: [{ id: 'c1' }] }],
      vista_creditos: () => [{ vista_creditos: [{ id: 'k1' }] }],
      listar_cdt_definiciones: () => [{ listar_cdt_definiciones: [{ id: 'd1' }] }],
    });
    const app = hacerApp(db); const c = await login(app, request);
    expect((await request(app).get('/api/transacciones').set('Cookie', c)).body).toEqual([{ id: 't1' }]);
    expect((await request(app).get('/api/cdts').set('Cookie', c)).body).toEqual([{ id: 'c1' }]);
    expect((await request(app).get('/api/creditos/mis-creditos').set('Cookie', c)).body).toEqual([{ id: 'k1' }]);
    expect((await request(app).get('/api/cdts/definiciones').set('Cookie', c)).body).toEqual([{ id: 'd1' }]);
    expect(llamada(db, 'listar_cdt_definiciones')).toEqual([UID]);
  });
  it.each([['50', 50], ['7', 7], [undefined, null], ['abc', null]])('limite=%s → vista_historial(usuario, %s)', async (q, n) => {
    const { db } = dbConUsuarios({ vista_historial: () => [{ vista_historial: [] }] });
    const app = hacerApp(db); const c = await login(app, request);
    await request(app).get('/api/transacciones' + (q === undefined ? '' : `?limite=${q}`)).set('Cookie', c);
    expect(llamada(db, 'vista_historial')).toEqual([UID, n]);
  });
  it('simuladores y destinatario llevan p_usuario_id primero', async () => {
    const { db } = dbConUsuarios({
      simular_cdt: () => [{ simular_cdt: { generado_vencimiento: 1 } }],
      simular_credito: () => [{ simular_credito: { cuota_mensual: 1 } }],
      nombre_destinatario: () => [{ nombre_destinatario: { nombre: 'X' } }],
      pagar_cuota: () => [{ pagar_cuota: { numero: 3 } }],
    });
    const app = hacerApp(db); const c = await login(app, request);
    await request(app).post('/api/cdts/simular').set('Cookie', c).send({ definicion_id: 'd', monto: 100 });
    await request(app).post('/api/creditos/simular').set('Cookie', c).send({ producto_id: 'p', monto: 100, plazo: 12 });
    await request(app).get('/api/destinatario/4003004005').set('Cookie', c);
    await request(app).post('/api/creditos/k1/pagar-cuota').set('Cookie', c).send({ numero: 3 });
    expect(llamada(db, 'simular_cdt')).toEqual([UID, 'd', 100]);
    expect(llamada(db, 'simular_credito')).toEqual([UID, 'p', 100, 12]);
    expect(llamada(db, 'nombre_destinatario')).toEqual([UID, '4003004005']);
    expect(llamada(db, 'pagar_cuota')).toEqual([UID, 'k1', 3]);
  });
  it('registro devuelve solo el username (nunca el usuario_id)', async () => {
    const { db } = dbConUsuarios({ registrar_usuario: () => [{ registrar_usuario: { usuario_id: UID, username: 'qprueba123' } }] });
    const r = await request(hacerApp(db)).post('/api/auth/registro').send({ password: 'Banco2026', acepta_politica: true });
    expect(r.body).toEqual({ username: 'qprueba123' });
  });
  it('admin: tabla pasa la página como texto tal cual; sin página → NULL', async () => {
    const { db } = dbConUsuarios({ admin_tabla: () => [{ admin_tabla: { filas: [] } }] });
    const app = hacerApp(db); const c = await login(app, request, 'admin1');
    await request(app).get('/api/admin/tabla/usuario?pagina=abc').set('Cookie', c);
    expect(llamada(db, 'admin_tabla')).toEqual([ADMIN, 'usuario', 'abc']);
    db.calls.length = 0;
    await request(app).get('/api/admin/tabla/usuario').set('Cookie', c);
    expect(llamada(db, 'admin_tabla')).toEqual([ADMIN, 'usuario', null]);
  });
});
