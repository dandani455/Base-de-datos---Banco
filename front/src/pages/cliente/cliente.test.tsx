import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import App from '../../App';
import EnvioForm from '../../components/EnvioForm';
import Creditos from './Creditos';

const resp = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));

type Ruta = (init?: RequestInit) => Promise<Response>;
function mockFetch(rutas: Record<string, Ruta>) {
  const f = vi.fn((url: string, init?: RequestInit) => {
    const clave = `${init?.method ?? 'GET'} ${url}`;
    const r = rutas[clave];
    return r ? r(init) : resp(404, { error: `sin mock ${clave}` });
  });
  vi.stubGlobal('fetch', f);
  return f;
}
const llamadas = (f: ReturnType<typeof vi.fn>, clave: string) =>
  f.mock.calls.filter((c) => `${(c[1] as RequestInit | undefined)?.method ?? 'GET'} ${c[0]}` === clave);

afterEach(() => vi.restoreAllMocks());

describe('EnvioForm', () => {
  it('muestra el nombre del destinatario antes de confirmar', async () => {
    const f = mockFetch({ 'GET /api/destinatario/123': () => resp(200, { nombre: 'Ana Gómez' }) });
    render(<EnvioForm />);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText(/número de cuenta destino/i), '123');
    await u.click(screen.getByRole('button', { name: /buscar destinatario/i }));
    expect(await screen.findByText('¿Envías a Ana Gómez?')).toBeInTheDocument();
    expect(llamadas(f, 'POST /api/envios')).toHaveLength(0);
  });

  it('doble clic en confirmar produce una sola llamada a POST /envios', async () => {
    let liberar!: () => void;
    const f = mockFetch({
      'GET /api/destinatario/123': () => resp(200, { nombre: 'Ana Gómez' }),
      'POST /api/envios': () => new Promise((res) => { liberar = () => res(new Response('{}', { status: 200 })); }),
    });
    render(<EnvioForm />);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText(/número de cuenta destino/i), '123');
    await u.click(screen.getByRole('button', { name: /buscar destinatario/i }));
    await screen.findByText('¿Envías a Ana Gómez?');
    await u.type(screen.getByLabelText('Monto'), '5000');
    const boton = screen.getByRole('button', { name: /confirmar envío/i });
    await u.dblClick(boton);
    expect(llamadas(f, 'POST /api/envios')).toHaveLength(1);
    expect(boton).toBeDisabled();
    liberar();
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Envío realizado'));
  });
});

describe('Panel cliente', () => {
  it('con 503 mantiene los menús y muestra el banner sin datos', async () => {
    mockFetch({
      'GET /api/yo': () => resp(200, { username: 'jperez42' }),
      'GET /api/dashboard': () => resp(503, {}),
    });
    render(<MemoryRouter initialEntries={['/app']}><App /></MemoryRouter>);
    expect(await screen.findByRole('alert')).toHaveTextContent(/error de conexión/i);
    for (const n of ['Inicio', 'Balance', 'Créditos', 'CDTs', 'Perfil']) {
      expect(screen.getByRole('link', { name: n })).toBeInTheDocument();
    }
    expect(screen.queryByTestId('transaccion')).toBeNull();
    expect(screen.queryByText(/balance total/i)).toBeNull();
  });

  it('sin sesión redirige a /login', async () => {
    mockFetch({ 'GET /api/yo': () => resp(401, { error: 'No autenticado' }) });
    render(<MemoryRouter initialEntries={['/app']}><App /></MemoryRouter>);
    expect(await screen.findByRole('heading', { name: 'Ingresar' })).toBeInTheDocument();
  });

  it('dashboard: envíos en rojo con "-", recibos en verde con "+"', async () => {
    mockFetch({
      'GET /api/yo': () => resp(200, { username: 'jperez42' }),
      'GET /api/dashboard': () => resp(200, {
        nombre: 'Juan', balance_total: 100000,
        transacciones: [
          { id: 1, tipo: 'envio', monto: 5000, fecha: '2026-11-10T15:30:00Z', contraparte: 'Ana' },
          { id: 2, tipo: 'recibo', monto: 7000, fecha: '2026-11-09T10:00:00Z', contraparte: 'Luis' },
        ],
        cdts: { activos: 2, generado: 1234 }, creditos: { cuota_por_pagar: 99000, interes_corriendo: 4321 },
      }),
    });
    render(<MemoryRouter initialEntries={['/app']}><App /></MemoryRouter>);
    expect(await screen.findByText(/hola, juan/i)).toBeInTheDocument();
    const [envio, recibo] = await screen.findAllByTestId('transaccion');
    expect(envio).toHaveTextContent(/^-/);
    expect(envio).toHaveStyle({ color: '#b00020' });
    expect(recibo).toHaveTextContent(/^\+/);
    expect(recibo).toHaveStyle({ color: '#1b7f3b' });
  });

  it('logout llama POST /auth/logout y vuelve a /login', async () => {
    const f = mockFetch({
      'GET /api/yo': () => resp(200, { username: 'jperez42' }),
      'GET /api/dashboard': () => resp(503, {}),
      'POST /api/auth/logout': () => resp(200, {}),
    });
    render(<MemoryRouter initialEntries={['/app']}><App /></MemoryRouter>);
    await userEvent.click(await screen.findByRole('button', { name: /cerrar sesión/i }));
    expect(await screen.findByRole('heading', { name: 'Ingresar' })).toBeInTheDocument();
    expect(llamadas(f, 'POST /api/auth/logout')).toHaveLength(1);
  });
});

describe('Créditos', () => {
  it('el simulador muestra los valores del backend sin calcular', async () => {
    mockFetch({
      'GET /api/creditos/productos': () => resp(200, [{ id: 1, nombre: 'Libre inversión', tasa: '1.8% mensual', monto_min: 1000000, monto_max: 20000000, plazo_min: 6, plazo_max: 48 }]),
      'GET /api/creditos/mis-creditos': () => resp(200, []),
      'POST /api/creditos/simular': () => resp(200, { cuota_mensual: 777777, total_a_pagar: 9999991, intereses_totales: 1234567 }),
    });
    render(<MemoryRouter><Creditos /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(await screen.findByLabelText('Monto'), '5000000');
    await u.type(screen.getByLabelText('Plazo (meses)'), '12');
    await u.click(screen.getByRole('button', { name: 'Simular' }));
    expect(await screen.findByText(/777\.777/)).toBeInTheDocument();
    expect(screen.getByText(/9\.999\.991/)).toBeInTheDocument();
    expect(screen.getByText(/1\.234\.567/)).toBeInTheDocument();
  });

  it('muestra tal cual el error de negocio al solicitar', async () => {
    mockFetch({
      'GET /api/creditos/productos': () => resp(200, [{ id: 1, nombre: 'Libre inversión', tasa: '1.8%', monto_min: 1, monto_max: 2, plazo_min: 1, plazo_max: 2 }]),
      'GET /api/creditos/mis-creditos': () => resp(200, []),
      'POST /api/creditos/simular': () => resp(200, { cuota_mensual: 1, total_a_pagar: 2, intereses_totales: 3 }),
      'POST /api/creditos': () => resp(400, { error: 'Ya tienes un crédito activo' }),
    });
    render(<MemoryRouter><Creditos /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(await screen.findByLabelText('Monto'), '5');
    await u.type(screen.getByLabelText('Plazo (meses)'), '1');
    await u.click(screen.getByRole('button', { name: 'Simular' }));
    await u.click(await screen.findByRole('button', { name: 'Solicitar este crédito' }));
    expect(await screen.findByText('Ya tienes un crédito activo')).toBeInTheDocument();
  });
});
