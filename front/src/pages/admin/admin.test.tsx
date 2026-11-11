import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import Control from './Control';
import Reloj from './Reloj';
import AdminLayout from './Layout';

const resp = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));

const esquema = {
  tablas: [
    { nombre: 'usuario', columnas: [{ nombre: 'id', llave: true, no_nulo: true }, { nombre: 'password_hash', no_nulo: true }], fks: [] },
    { nombre: 'cuenta', columnas: [{ nombre: 'id', llave: true }, { nombre: 'usuario_id', no_nulo: true, unico: true }], fks: [{ columna: 'usuario_id', tabla_destino: 'usuario' }] },
  ],
};

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('Control', () => {
  it('con respuesta lenta solo hay 1 peticion en vuelo aunque pasen 20 s', async () => {
    vi.useFakeTimers();
    const f = vi.fn(() => new Promise<Response>(() => {})); // nunca responde
    vi.stubGlobal('fetch', f);
    render(<Control />);
    await act(async () => { await vi.advanceTimersByTimeAsync(20000); });
    expect(f).toHaveBeenCalledTimes(1);
  });

  it('no hace ping con la pestana oculta', async () => {
    vi.useFakeTimers();
    const f = vi.fn(() => resp(200, esquema));
    vi.stubGlobal('fetch', f);
    vi.spyOn(document, 'hidden', 'get').mockReturnValue(true);
    render(<Control />);
    await act(async () => { await vi.advanceTimersByTimeAsync(20000); });
    expect(f).not.toHaveBeenCalled();
  });

  it('503 muestra DESCONECTADO y 200 CONECTADO', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(503, {})));
    const { unmount } = render(<Control />);
    expect(await screen.findByText('DESCONECTADO')).toBeInTheDocument();
    unmount();
    vi.stubGlobal('fetch', vi.fn(() => resp(200, esquema)));
    render(<Control />);
    expect(await screen.findByText('CONECTADO')).toBeInTheDocument();
  });

  it('la tabla usuario muestra el valor enmascarado como texto plano', async () => {
    const f = vi.fn((url: string) =>
      url.includes('/admin/tabla/usuario')
        ? resp(200, { columnas: ['id', 'password_hash'], filas: [{ id: 1, password_hash: '••••' }], pagina: 1, total_paginas: 1 })
        : resp(200, esquema));
    vi.stubGlobal('fetch', f);
    render(<Control />);
    const u = userEvent.setup();
    await u.click(await screen.findByRole('button', { name: /tabla usuario/i }));
    expect(await screen.findByText('••••')).toBeInTheDocument();
    expect(document.body.innerHTML).not.toMatch(/\$2[aby]\$|argon2/);
    expect(f.mock.calls.some((c) => String((c as unknown[])[0]).includes('/api/admin/tabla/usuario?pagina=1'))).toBe(true);
  });
});

describe('Reloj', () => {
  it('el selector no permite fechas anteriores a la actual', async () => {
    const f = vi.fn((_u: string, init?: RequestInit) =>
      init?.method === 'PUT' ? resp(200, {}) : resp(200, { usar_fecha_real: false, fecha_sistema: '2026-11-10', fecha_actual: '2026-11-10' }));
    vi.stubGlobal('fetch', f);
    render(<Reloj />);
    const input = await screen.findByLabelText('Fecha del sistema');
    expect(input).toHaveAttribute('min', '2026-11-10');
    fireEvent.change(input, { target: { value: '2026-11-01' } });
    const guardar = screen.getByRole('button', { name: 'Guardar' });
    expect(guardar).toBeDisabled();
    fireEvent.change(input, { target: { value: '2026-11-20' } });
    expect(guardar).toBeEnabled();
  });
});

describe('AdminLayout', () => {
  it('redirige a /app si el rol no es ADMIN', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(200, { username: 'x', rol: 'CLIENTE' })));
    render(<MemoryRouter initialEntries={['/admin']}><AdminLayout /></MemoryRouter>);
    await waitFor(() => expect(screen.queryByText('Cargando…')).not.toBeInTheDocument());
    expect(screen.queryByRole('navigation', { name: /administrador/i })).not.toBeInTheDocument();
  });
});
