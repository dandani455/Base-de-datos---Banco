import { useEffect, useState } from 'react';
import { Navigate, NavLink, Outlet, useNavigate } from 'react-router-dom';
import { api } from '../../api/client';
import type { Yo } from '../../api/types';

const TABS = [['/app', 'Inicio'], ['/app/balance', 'Balance'], ['/app/creditos', 'Créditos'], ['/app/cdts', 'CDTs'], ['/app/perfil', 'Perfil']] as const;

export default function ClienteLayout() {
  const nav = useNavigate();
  const [estado, setEstado] = useState<'cargando' | 'ok' | 'anonimo' | 'admin'>('cargando');
  const [yo, setYo] = useState<Yo | null>(null);

  useEffect(() => {
    api<Yo>('/yo').then(
      (d) => { setYo(d); setEstado(d.rol === 'ADMIN' ? 'admin' : 'ok'); },
      // Sin conexión: se mantienen los menús (el banner global informa); cualquier otro fallo = sin sesión.
      (e) => setEstado((e as Error).name === 'ConexionError' ? 'ok' : 'anonimo'),
    );
  }, []);

  async function salir() {
    try { await api('/auth/logout', { method: 'POST' }); } catch { /* aun así se sale */ }
    nav('/login');
  }

  if (estado === 'anonimo') return <Navigate to="/login" replace />;
  if (estado === 'admin') return <Navigate to="/admin" replace />;
  if (estado === 'cargando') return <main>Cargando…</main>;
  return (
    <main>
      <nav className="nav" aria-label="Menú del cliente">
        {TABS.map(([to, texto]) => <NavLink key={to} to={to} end>{texto}</NavLink>)}
        <span>{yo?.username}</span>
        <button onClick={salir}>Cerrar sesión</button>
      </nav>
      <Outlet />
    </main>
  );
}
