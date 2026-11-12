import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import Demo from './Demo';

const resp = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));

function montar() {
  render(
    <MemoryRouter initialEntries={['/demo']}>
      <Routes>
        <Route path="/demo" element={<Demo />} />
        <Route path="/app" element={<p>panel cliente</p>} />
        <Route path="/admin" element={<p>panel admin</p>} />
      </Routes>
    </MemoryRouter>,
  );
}

afterEach(() => vi.restoreAllMocks());

describe('Demo', () => {
  it('entra al panel de cliente con el login del mock', async () => {
    const f = vi.fn(() => resp(200, { username: 'jperez483', rol: 'CLIENTE' }));
    vi.stubGlobal('fetch', f);
    montar();
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Entrar' })[0]);
    await waitFor(() => expect(screen.getByText('panel cliente')).toBeInTheDocument());
    const [path, init] = f.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe('/api/auth/login');
    expect(JSON.parse(init.body as string).username).toBe('jperez483');
  });

  it('entra al panel de administracion', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(200, { username: 'admin1', rol: 'ADMIN' })));
    montar();
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Entrar' })[1]);
    await waitFor(() => expect(screen.getByText('panel admin')).toBeInTheDocument());
  });

  it('la cuenta restringida muestra el mensaje del servidor y no navega', async () => {
    vi.stubGlobal('fetch', vi.fn(() => resp(400, { error: 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla' })));
    montar();
    await userEvent.setup().click(screen.getByRole('button', { name: 'Probar' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(/restringida/);
    expect(screen.queryByText('panel cliente')).not.toBeInTheDocument();
  });
});
