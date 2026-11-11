import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import App from './App';
import ErrorBanner from './components/ErrorBanner';
import { api } from './api/client';
import { useCarga } from './api/useApi';
import Usuarios from './pages/admin/Usuarios';
import Control from './pages/admin/Control';
import Operaciones from './pages/admin/Operaciones';
import Reloj from './pages/admin/Reloj';
import Creditos from './pages/cliente/Creditos';
import Cdts from './pages/cliente/Cdts';
import Dashboard from './pages/cliente/Dashboard';
import Simulador from './components/Simulador';

const resp = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));
type Ruta = (init?: RequestInit) => Promise<Response>;
function mockFetch(rutas: Record<string, Ruta>) {
  const f = vi.fn((url: string, init?: RequestInit) => {
    const r = rutas[`${init?.method ?? 'GET'} ${url}`];
    return r ? r(init) : resp(404, { error: 'sin mock' });
  });
  vi.stubGlobal('fetch', f);
  return f;
}
const llamadas = (f: ReturnType<typeof vi.fn>, clave: string) =>
  f.mock.calls.filter((c) => `${(c[1] as RequestInit | undefined)?.method ?? 'GET'} ${c[0]}` === clave);

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('1. sin datos viejos tras un 503', () => {
  it('useCarga descarta el dato al recargar con 503', async () => {
    let n = 0;
    mockFetch({ 'GET /api/x': () => (n++ === 0 ? resp(200, { v: 777 }) : resp(503, {})) });
    function C() {
      const { data, recargar } = useCarga<{ v: number }>('/x');
      return <><button onClick={recargar}>recargar</button>{data && <p>valor {data.v}</p>}</>;
    }
    render(<C />);
    expect(await screen.findByText('valor 777')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'recargar' }));
    await waitFor(() => expect(screen.queryByText('valor 777')).toBeNull());
  });

  it('Usuarios limpia lista y detalle con 503', async () => {
    let n = 0;
    mockFetch({
      'GET /api/admin/usuarios?busqueda=': () => resp(200, [{ id: 1, username: 'jperez42', nombre: 'Juan', numero_cuenta: '1', estado: 'ACTIVO' }]),
      'GET /api/admin/usuarios?busqueda=a': () => (n++ >= 0 ? resp(503, {}) : resp(200, [])),
      'GET /api/admin/usuarios/1': () => resp(200, { id: 1, nombre: 'Juan', estado: 'ACTIVO', cedula: '1', correo: 'a@b', numero_cuenta: '1', balance: { total: 5, principal: 5, bolsillos: [], cdts: [], creditos: [] }, historial: [] }),
    });
    render(<Usuarios />);
    await userEvent.click(await screen.findByRole('button', { name: 'Ver' }));
    expect(await screen.findByLabelText('Detalle de usuario')).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText(/buscar/i), 'a');
    await waitFor(() => expect(screen.queryByText('jperez42')).toBeNull());
    expect(screen.queryByLabelText('Detalle de usuario')).toBeNull();
  });
});

const esquema = { tablas: [{ nombre: 'usuario', columnas: [{ nombre: 'id', llave: true }], fks: [] }] };
const pagina = { columnas: ['id'], filas: [{ id: 4242 }], pagina: 1, total_paginas: 1 };

describe('5. Control refresca la tabla seleccionada y limpia con 503', () => {
  it('refetch en cada tick y filas fuera con 503', async () => {
    vi.useFakeTimers();
    let tablaN = 0;
    const f = vi.fn((url: string) => {
      if (url.includes('/admin/tabla/')) return ++tablaN === 1 ? resp(200, pagina) : resp(503, {});
      return resp(200, esquema);
    });
    vi.stubGlobal('fetch', f);
    render(<Control />);
    await act(async () => { await vi.advanceTimersByTimeAsync(10); });
    fireEvent.click(screen.getByRole('button', { name: /tabla usuario/i }));
    await act(async () => { await vi.advanceTimersByTimeAsync(10); });
    expect(screen.getByText('4242')).toBeInTheDocument();
    await act(async () => { await vi.advanceTimersByTimeAsync(5100); });
    expect(tablaN).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText('4242')).toBeNull();
  });
});

describe('2. anti doble clic', () => {
  const prod = { id: 1, nombre: 'Libre', tasa: '1%', monto_min: 1, monto_max: 2, plazo_min: 1, plazo_max: 2 };
  it('Simulador: Solicitar crédito una sola vez', async () => {
    let liberar!: () => void;
    const f = mockFetch({
      'GET /api/creditos/productos': () => resp(200, [prod]),
      'GET /api/creditos/mis-creditos': () => resp(200, []),
      'POST /api/creditos/simular': () => resp(200, { cuota_mensual: 1, total_a_pagar: 2, intereses_totales: 3 }),
      'POST /api/creditos': () => new Promise((r) => { liberar = () => r(new Response('{}', { status: 200 })); }),
    });
    render(<MemoryRouter><Creditos /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(await screen.findByLabelText('Monto'), '5');
    await u.type(screen.getByLabelText('Plazo (meses)'), '1');
    await u.click(screen.getByRole('button', { name: 'Simular' }));
    const b = await screen.findByRole('button', { name: 'Solicitar este crédito' });
    await u.dblClick(b);
    expect(llamadas(f, 'POST /api/creditos')).toHaveLength(1);
    expect(b).toBeDisabled();
    liberar();
    await waitFor(() => expect(b).toBeEnabled());
  });

  it('Abonar a capital una sola vez', async () => {
    let liberar!: () => void;
    const f = mockFetch({
      'GET /api/creditos/productos': () => resp(200, []),
      'GET /api/creditos/mis-creditos': () => resp(200, [{ id: 9, producto: 'Libre', cuotas_pagadas: 0, cuotas_faltantes: 3, interes_mes: 1 }]),
      'POST /api/creditos/9/abono': () => new Promise((r) => { liberar = () => r(new Response('{}', { status: 200 })); }),
    });
    render(<MemoryRouter><Creditos /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(await screen.findByLabelText('Abono Libre'), '100');
    const b = screen.getByRole('button', { name: 'Abonar a capital' });
    await u.dblClick(b);
    expect(llamadas(f, 'POST /api/creditos/9/abono')).toHaveLength(1);
    liberar();
    await waitFor(() => expect(screen.getByLabelText('Abono Libre')).toHaveValue(null));
  });

  it('Operaciones: Añadir balance una sola vez', async () => {
    let liberar!: () => void;
    const f = mockFetch({
      'POST /api/admin/balance': () => new Promise((r) => { liberar = () => r(new Response('{}', { status: 200 })); }),
    });
    render(<Operaciones />);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText(/usuario/i), '1');
    await u.type(screen.getByLabelText('Monto'), '100');
    const b = screen.getByRole('button', { name: 'Añadir balance' });
    await u.dblClick(b);
    expect(llamadas(f, 'POST /api/admin/balance')).toHaveLength(1);
    liberar();
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Balance añadido'));
  });
});

describe('3. Simulador no envía lo que no simuló', () => {
  it('cambiar un input oculta Solicitar hasta volver a simular', async () => {
    mockFetch({ 'POST /api/cdts/simular': () => resp(200, { generado: 1 }) });
    render(<Simulador titulo="Sim" endpoint="/cdts/simular" campos={[{ name: 'monto', label: 'Monto' }]}
      resultados={[{ clave: 'generado', etiqueta: 'G' }]} accion={{ etiqueta: 'Crear', endpoint: '/cdts' }} />);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText('Monto'), '100');
    await u.click(screen.getByRole('button', { name: 'Simular' }));
    expect(await screen.findByRole('button', { name: 'Crear' })).toBeInTheDocument();
    await u.type(screen.getByLabelText('Monto'), '9');
    expect(screen.queryByRole('button', { name: 'Crear' })).toBeNull();
  });

  it('cambiar el producto limpia el resultado', async () => {
    const defs = [{ id: 1, nombre: 'A', tasa: '1', plazo_dias: 30, monto_min: 1 }, { id: 2, nombre: 'B', tasa: '1', plazo_dias: 60, monto_min: 1 }];
    mockFetch({
      'GET /api/cdts/definiciones': () => resp(200, defs), 'GET /api/cdts': () => resp(200, []),
      'POST /api/cdts/simular': () => resp(200, { generado_mes: 1, generado_dia: 1, generado_vencimiento: 1 }),
    });
    render(<MemoryRouter><Cdts /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(await screen.findByLabelText('Monto'), '100');
    await u.click(screen.getByRole('button', { name: 'Simular' }));
    expect(await screen.findByRole('button', { name: 'Crear CDT' })).toBeInTheDocument();
    await u.selectOptions(screen.getByLabelText('Definición'), '2');
    expect(screen.queryByRole('button', { name: 'Crear CDT' })).toBeNull();
  });
});

describe('4. Dashboard pasa bolsillos al envío', () => {
  it('muestra "Desde" y envía bolsillo_origen', async () => {
    const f = mockFetch({
      'GET /api/dashboard': () => resp(200, { nombre: 'Juan', balance_total: 1, transacciones: [], cdts: { activos: 0, generado: 0 }, creditos: { cuota_por_pagar: 0, interes_corriendo: 0 } }),
      'GET /api/bolsillos': () => resp(200, { total: 1, principal: 1, bolsillos: [{ id: 7, nombre: 'Viaje', saldo: 0 }] }),
      'GET /api/destinatario/123': () => resp(200, { nombre: 'Ana' }),
      'POST /api/envios': () => resp(200, {}),
    });
    render(<MemoryRouter><Dashboard /></MemoryRouter>);
    const u = userEvent.setup();
    await u.type(screen.getByLabelText(/número de cuenta destino/i), '123');
    await u.click(screen.getByRole('button', { name: /buscar destinatario/i }));
    await screen.findByText('¿Envías a Ana?');
    await u.type(screen.getByLabelText('Monto'), '5');
    await u.selectOptions(await screen.findByLabelText('Desde'), '7');
    await u.click(screen.getByRole('button', { name: /confirmar envío/i }));
    await waitFor(() => expect(llamadas(f, 'POST /api/envios')).toHaveLength(1));
    expect(JSON.parse(llamadas(f, 'POST /api/envios')[0][1].body)).toMatchObject({ bolsillo_origen: '7' });
  });
});

describe('6. admin no se queda en el panel cliente', () => {
  it('/app con rol ADMIN redirige a /admin', async () => {
    mockFetch({ 'GET /api/yo': () => resp(200, { username: 'root', rol: 'ADMIN' }) });
    render(<MemoryRouter initialEntries={['/app']}><App /></MemoryRouter>);
    expect(await screen.findByRole('navigation', { name: /administrador/i })).toBeInTheDocument();
  });
});

describe('7. el banner se oculta al reconectar', () => {
  it('conexion-restablecida lo oculta; una respuesta 400 la dispara', async () => {
    render(<ErrorBanner />);
    act(() => { window.dispatchEvent(new Event('conexion-perdida')); });
    expect(screen.getByRole('alert')).toBeInTheDocument();
    vi.stubGlobal('fetch', vi.fn(() => resp(400, { error: 'x' })));
    await expect(api('/x')).rejects.toBeDefined();
    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull());
  });

  it('un 503 no la dispara', async () => {
    const l = vi.fn();
    window.addEventListener('conexion-restablecida', l);
    vi.stubGlobal('fetch', vi.fn(() => resp(503, {})));
    await expect(api('/x')).rejects.toBeDefined();
    window.removeEventListener('conexion-restablecida', l);
    expect(l).not.toHaveBeenCalled();
  });
});

describe('8. Reloj tolera fecha_sistema null', () => {
  it('no truena con usar_fecha_real y fecha_sistema null', async () => {
    mockFetch({ 'GET /api/admin/reloj': () => resp(200, { usar_fecha_real: true, fecha_sistema: null, fecha_actual: '2026-11-10' }) });
    render(<Reloj />);
    expect(await screen.findByText(/2026-11-10/)).toBeInTheDocument();
  });
});
