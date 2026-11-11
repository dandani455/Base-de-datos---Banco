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
  if (estado === 'cargando') return <main className="cargando">Cargando…</main>;
  return (
    <div className="app admin">
      <nav className="side" aria-label="Menú del administrador">
        <span className="marca">Banco Digital</span>
        <div className="side-links">
          {TABS.map(([to, texto]) => <NavLink key={to} to={to} end>{texto}</NavLink>)}
        </div>
        <div className="side-pie">
          <button className="sec salir" onClick={salir}>Cerrar sesión</button>
        </div>
      </nav>
      <main className="contenido">
        <Outlet />
      </main>
    </div>
  );
}
