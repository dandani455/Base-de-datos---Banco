import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { BLOQ, ADMIN, UID, dbConUsuarios, hacerApp, login, negocio } from './helpers';

const post = (app: any, u: string, p: string) => request(app).post('/api/auth/login').send({ username: u, password: p });

describe('login', () => {
  it('OK: cookie HttpOnly SameSite=Lax, sin token en el body', async () => {
    const { db } = dbConUsuarios(); const app = hacerApp(db);
    const r = await post(app, 'jperez483', 'Banco2026');
    expect(r.status).toBe(200); expect(r.body).toEqual({ username: 'jperez483', rol: 'CLIENTE' });
    const c = (r.headers['set-cookie'] as unknown as string[])[0];
    expect(c).toMatch(/HttpOnly/i); expect(c).toMatch(/SameSite=Lax/i); expect(c).not.toMatch(/Secure/i);
    expect(JSON.stringify(r.body)).not.toMatch(/eyJ/);
  });
  it('clave mala y usuario inexistente dan el mismo error', async () => {
    const { db } = dbConUsuarios(); const app = hacerApp(db);
    const a = await post(app, 'jperez483', 'Mala12345'), b = await post(app, 'nadie', 'Banco2026');
    expect(a.status).toBe(400); expect(b.status).toBe(400); expect(a.body).toEqual(b.body);
    expect(a.body.error).toBe('Credenciales inválidas');
  });
  it('bloqueado → mensaje exacto de la BD', async () => {
    const { db, estado } = dbConUsuarios(); estado[UID] = 'BLOQUEADO';
    const r = await post(hacerApp(db), 'jperez483', 'Banco2026');
    expect(r.status).toBe(400); expect(r.body.error).toBe(BLOQ);
  });
  it('sesión abierta + bloqueo posterior → /api/yo devuelve el mensaje', async () => {
    const { db, estado } = dbConUsuarios(); const app = hacerApp(db);
    const cookie = await login(app, request);
    expect((await request(app).get('/api/yo').set('Cookie', cookie)).status).toBe(200);
    estado[UID] = 'BLOQUEADO';
    const r = await request(app).get('/api/yo').set('Cookie', cookie);
    expect(r.status).toBe(400); expect(r.body.error).toBe(BLOQ);
  });
  it('el 6.º intento fallido → 429 (por usuario)', async () => {
    const { db } = dbConUsuarios(); const app = hacerApp(db);
    for (let i = 0; i < 5; i++) expect((await post(app, 'jperez483', 'Mala12345')).status).toBe(400);
    expect((await post(app, 'jperez483', 'Banco2026')).status).toBe(429);
  });
  it('cookie manipulada o ausente → 401', async () => {
    const { db } = dbConUsuarios(); const app = hacerApp(db);
    expect((await request(app).get('/api/yo')).status).toBe(401);
    expect((await request(app).get('/api/yo').set('Cookie', 'sid=falso')).status).toBe(401);
  });
  it('logout limpia la cookie', async () => {
    const { db } = dbConUsuarios(); const r = await request(hacerApp(db)).post('/api/auth/logout');
    expect((r.headers['set-cookie'] as unknown as string[])[0]).toMatch(/sid=;/);
  });
});

describe('registro', () => {
  const body = { nombres: 'Juan', apellidos: 'Pérez', cedula: '1', correo: 'a@b.co', telefono: '3', fecha_nacimiento: '2000-01-01', password: 'Banco2026', acepta_politica: true };
  it('hashea la clave (la BD nunca la ve en claro) y devuelve username', async () => {
    const { db } = dbConUsuarios({ registrar_usuario: () => [{ registrar_usuario: { usuario_id: UID, username: 'jperez483' } }] });
    const r = await request(hacerApp(db)).post('/api/auth/registro').send({ ...body, codigo_referido: 'abc' });
    expect(r.body).toEqual({ username: 'jperez483' });
    const args = (db as any).calls.find((c: any) => c[0] === 'registrar_usuario')[1];
    expect(args[6]).toMatch(/^\$2[aby]\$/); expect(args).not.toContain('Banco2026');
    expect(args[8]).toBe('abc'); expect(args[9]).toBe(false); // RESEND_ENABLED apagado
  });
  it.each(['corta1A', 'sinmayuscula1', 'SinNumeroAqui'])('contraseña débil %s → 400 sin llamar a la BD', async (p) => {
    const { db } = dbConUsuarios();
    const r = await request(hacerApp(db)).post('/api/auth/registro').send({ ...body, password: p });
    expect(r.status).toBe(400); expect((db as any).calls.some((c: any) => c[0] === 'registrar_usuario')).toBe(false);
  });
  it('error de la BD (política no aceptada) pasa tal cual', async () => {
    const { db } = dbConUsuarios({ registrar_usuario: () => { throw negocio('Debe aceptar la política de datos'); } });
    const r = await request(hacerApp(db)).post('/api/auth/registro').send({ ...body, acepta_politica: false });
    expect(r.status).toBe(400); expect(r.body.error).toBe('Debe aceptar la política de datos');
  });
});
