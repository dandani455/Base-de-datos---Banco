import { useEffect, useState } from 'react';
import { Navigate, NavLink, Outlet, useNavigate } from 'react-router-dom';
import { api } from '../../api/client';
import type { Yo } from '../../api/types';

const TABS = [['/admin', 'Usuarios'], ['/admin/operaciones', 'Operaciones'], ['/admin/reloj', 'Reloj'], ['/admin/tasas', 'Tasas'], ['/admin/control', 'Control']] as const;

export default function AdminLayout() {
  const nav = useNavigate();
  const [estado, setEstado] = useState<'cargando' | 'ok' | 'anonimo' | 'cliente'>('cargando');

  useEffect(() => {
    api<Yo>('/yo').then(
      (d) => setEstado(d.rol === 'ADMIN' ? 'ok' : 'cliente'),
      (e) => setEstado((e as Error).name === 'ConexionError' ? 'ok' : 'anonimo'),
    );
  }, []);

  async function salir() {
    try { await api('/auth/logout', { method: 'POST' }); } catch { /* aun así se sale */ }
    nav('/login');
  }

  if (estado === 'anonimo') return <Navigate to="/login" replace />;
  if (estado === 'cliente') return <Navigate to="/app" replace />;
  if (estado === 'cargando') return <main>Cargando…</main>;
  return (
    <main>
      <nav className="nav" aria-label="Menú del administrador">
        {TABS.map(([to, texto]) => <NavLink key={to} to={to} end>{texto}</NavLink>)}
        <button onClick={salir}>Cerrar sesión</button>
      </nav>
      <Outlet />
    </main>
  );
}
