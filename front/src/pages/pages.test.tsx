import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import Registro from './Registro';
import Login from './Login';
import Inicio from './Inicio';

const resp = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));

afterEach(() => vi.restoreAllMocks());

describe('Registro', () => {
  it('envia ?ref como codigo_referido y muestra el usuario una vez', async () => {
    const f = vi.fn(() => resp(200, { username: 'jperez42' }));
    vi.stubGlobal('fetch', f);
    const ref = '123e4567-e89b-12d3-a456-426614174000';
    render(<MemoryRouter initialEntries={[`/registro?ref=${ref}`]}><Registro /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText('Nombres'), 'Juan');
    await u.type(screen.getByLabelText('Apellidos'), 'Perez');
    await u.type(screen.getByLabelText('Cédula'), '1234567');
    await u.type(screen.getByLabelText('Correo'), 'j@x.co');
    await u.type(screen.getByLabelText('Teléfono'), '3001234567');
    await u.type(screen.getByLabelText('Fecha de nacimiento'), '1990-01-01');
    await u.type(screen.getByLabelText('Contraseña'), 'Abcdefg1');
    await u.click(screen.getByLabelText(/política de datos/i));
    await u.click(screen.getByRole('button', { name: 'Registrarse' }));
    await waitFor(() => expect(screen.getByText(/jperez42/)).toBeInTheDocument());
    const [path, init] = f.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe('/api/auth/registro');
    expect(JSON.parse(init.body as string).codigo_referido).toBe(ref);
  });

  it('valida la contrasena en vivo', async () => {
    render(<MemoryRouter><Registro /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText('Contraseña'), 'abc');
    expect(screen.getByText(/mínimo 8 caracteres/i)).toHaveAttribute('data-ok', 'false');
    await u.clear(screen.getByLabelText('Contraseña'));
    await u.type(screen.getByLabelText('Contraseña'), 'Abcdefg1');
    expect(screen.getByText(/mínimo 8 caracteres/i)).toHaveAttribute('data-ok', 'true');
    expect(screen.getByText(/una mayúscula/i)).toHaveAttribute('data-ok', 'true');
    expect(screen.getByText(/un número/i)).toHaveAttribute('data-ok', 'true');
  });
});

describe('Login', () => {
  it('muestra tal cual el mensaje de bloqueo', async () => {
    const msg = 'Tu cuenta ha sido restringida, contacte con el banco para desbloquearla';
    vi.stubGlobal('fetch', vi.fn(() => resp(400, { error: msg })));
    render(<MemoryRouter><Login /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText('Usuario'), 'jperez42');
    await u.type(screen.getByLabelText('Contraseña'), 'x');
    await u.click(screen.getByRole('button', { name: 'Ingresar' }));
    expect(await screen.findByText(msg)).toBeInTheDocument();
  });
});

describe('Ingresar y Registro', () => {
  it('el titulo del formulario no lleva ninguna etiqueta encima y el panel no repite viñetas', () => {
    for (const Pagina of [Login, Registro]) {
      const { container, unmount } = render(<MemoryRouter><Pagina /></MemoryRouter>);
      expect(container.querySelector('main')!.firstElementChild!.tagName).toBe('H1');
      expect(container.querySelector('.auth-puntos')).toBeNull();
      expect(container.querySelectorAll('.foto')).toHaveLength(1);
      unmount();
    }
  });
});

describe('Inicio', () => {
  it('usa fallback estatico si la API de productos falla', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new TypeError('down'))));
    render(<MemoryRouter><Inicio /></MemoryRouter>);
    expect(screen.getByRole('heading', { name: 'Banco Digital', level: 1 })).toBeInTheDocument();
    expect(screen.getByText(/invita y gana \$50\.000/i)).toBeInTheDocument();
    expect(await screen.findAllByTestId('producto')).toHaveLength(4);
  });

  it('las piezas decorativas (telefono, tarjeta, ilustraciones) quedan fuera del arbol accesible', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new TypeError('down'))));
    const { container } = render(<MemoryRouter><Inicio /></MemoryRouter>);
    expect(screen.getAllByRole('heading', { level: 1 })).toHaveLength(1);
    for (const sel of ['.escena', '.tarjeta', '.panel-frag']) {
      const els = container.querySelectorAll(sel);
      expect(els.length, sel).toBeGreaterThan(0);
      els.forEach((el) => expect(el.closest('[aria-hidden="true"]'), sel).not.toBeNull());
    }
    expect(screen.getAllByRole('tabpanel', { hidden: true })).toHaveLength(4);
    expect(await screen.findAllByTestId('producto')).toHaveLength(4);
  });

  it('las reglas de la landing no chocan con los paneles: ninguna seccion usa la clase sec', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new TypeError('down'))));
    const { container } = render(<MemoryRouter><Inicio /></MemoryRouter>);
    expect(container.querySelector('.sec')).toBeNull();
    expect(container.querySelector('.cifras')).toBeNull();
    expect(await screen.findAllByTestId('producto')).toHaveLength(4);
  });

  it('la unica foto de la landing va en el marco comun, con su recorte y sin nada encima', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new TypeError('down'))));
    const { container } = render(<MemoryRouter><Inicio /></MemoryRouter>);
    const fotos = container.querySelectorAll('img');
    expect(fotos).toHaveLength(1);
    const marco = fotos[0].parentElement!;
    expect(marco).toHaveClass('foto', 'foto-vertical');
    expect(marco.children).toHaveLength(1);
    expect(fotos[0].style.objectPosition).not.toBe('');
    expect(fotos[0]).toHaveAttribute('alt', expect.stringMatching(/Bogotá/));
    expect(await screen.findAllByTestId('producto')).toHaveLength(4);
  });
});
