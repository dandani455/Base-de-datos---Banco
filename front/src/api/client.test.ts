import { afterEach, describe, expect, it, vi } from 'vitest';
import { api, ConexionError, NegocioError } from './client';

const resp = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));

afterEach(() => vi.restoreAllMocks());

describe('api client', () => {
  it('503 rechaza ConexionError y dispara conexion-perdida', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(503, {})));
    const listener = vi.fn();
    window.addEventListener('conexion-perdida', listener);
    await expect(api('/x')).rejects.toBeInstanceOf(ConexionError);
    expect(listener).toHaveBeenCalledTimes(1);
    window.removeEventListener('conexion-perdida', listener);
  });

  it('fallo de red tambien se trata como conexion perdida', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new TypeError('network'))));
    await expect(api('/x')).rejects.toBeInstanceOf(ConexionError);
  });

  it('400 rechaza NegocioError con el mensaje del servidor', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(400, { error: 'Saldo insuficiente' })));
    await expect(api('/x')).rejects.toMatchObject({ name: 'NegocioError', message: 'Saldo insuficiente' });
    await expect(api('/x')).rejects.toBeInstanceOf(NegocioError);
  });

  it('otros errores rechazan Error generico', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(500, {})));
    const e = await api('/x').catch((x) => x);
    expect(e).toBeInstanceOf(Error);
    expect(e).not.toBeInstanceOf(NegocioError);
  });

  it('usa credentials include y no toca localStorage', async () => {
    const f = vi.fn(() => resp(200, { ok: 1 }));
    vi.stubGlobal('fetch', f);
    const spy = vi.spyOn(Storage.prototype, 'setItem');
    await expect(api('/x')).resolves.toEqual({ ok: 1 });
    expect(f).toHaveBeenCalledWith('/api/x', expect.objectContaining({ credentials: 'include' }));
    expect(spy).not.toHaveBeenCalled();
  });
});
