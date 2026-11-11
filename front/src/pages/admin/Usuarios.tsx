import { useEffect, useState } from 'react';
import { api } from '../../api/client';
import { mensaje } from '../../api/useApi';
import type { AdminUsuario, AdminUsuarioDetalle } from '../../api/types';
import { moneda } from '../../format';
import TransaccionList from '../../components/TransaccionList';

export default function Usuarios() {
  const [busqueda, setBusqueda] = useState('');
  const [lista, setLista] = useState<AdminUsuario[]>([]);
  const [detalle, setDetalle] = useState<AdminUsuarioDetalle | null>(null);
  const [err, setErr] = useState('');
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let vivo = true;
    api<AdminUsuario[]>(`/admin/usuarios?busqueda=${encodeURIComponent(busqueda)}`).then(
      (d) => { if (vivo) { setLista(d); setErr(''); } },
      (e) => { if (vivo) { setErr(mensaje(e)); setLista([]); setDetalle(null); } });
    return () => { vivo = false; };
  }, [busqueda, tick]);

  async function ver(id: string | number) {
    try { setDetalle(await api<AdminUsuarioDetalle>(`/admin/usuarios/${id}`)); setErr(''); }
    catch (e) { setErr(mensaje(e)); if ((e as Error).name === 'ConexionError') setDetalle(null); }
  }

  async function accion(u: AdminUsuario, que: 'bloquear' | 'desbloquear' | 'borrar') {
    if (que === 'borrar' && !window.confirm(`¿Borrar al usuario ${u.username}? Esta acción no se puede deshacer.`)) return;
    try {
      await api(que === 'borrar' ? `/admin/usuarios/${u.id}` : `/admin/usuarios/${u.id}/${que}`,
        { method: que === 'borrar' ? 'DELETE' : 'POST' });
      if (que === 'borrar') setDetalle(null); else if (detalle) ver(detalle.id);
      setTick((t) => t + 1);
    } catch (e) { setErr(mensaje(e)); }
  }

  return (
    <>
      <h1>Usuarios</h1>
      <label className="buscar">Buscar (nombre, cédula, correo o número de cuenta)
        <input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} />
      </label>
      {err && <p role="alert">{err}</p>}
      <div className="tabla-wrap"><table>
        <thead><tr><th>Usuario</th><th>Nombre</th><th>Cuenta</th><th>Estado</th><th>Acciones</th></tr></thead>
        <tbody>
          {lista.map((u) => (
            <tr key={u.id}>
              <td>{u.username}</td><td>{u.nombre}</td><td>{u.numero_cuenta}</td><td><span className={`estado ${u.estado === 'BLOQUEADO' ? 'bloq' : 'act'}`}>{u.estado}</span></td>
              <td className="acciones">
                <button className="sec" onClick={() => ver(u.id)}>Ver</button>
                {u.estado === 'BLOQUEADO'
                  ? <button className="sec" onClick={() => accion(u, 'desbloquear')}>Desbloquear</button>
                  : <button className="sec" onClick={() => accion(u, 'bloquear')}>Bloquear</button>}
                <button className="peligro" onClick={() => accion(u, 'borrar')}>Borrar</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table></div>
      {detalle && (
        <section aria-label="Detalle de usuario" className="panel detalle">
          <h2>{detalle.nombre} ({detalle.estado})</h2>
          <p>Cédula {detalle.cedula} · {detalle.correo} · Cuenta {detalle.numero_cuenta}</p>
          <p>Balance total: {moneda(detalle.balance.total)}</p>
          <ul className="lista-simple">
            <li>Principal: {moneda(detalle.balance.principal)}</li>
            {detalle.balance.bolsillos.map((b) => <li key={b.id}>Bolsillo {b.nombre}: {moneda(b.saldo)}</li>)}
            {detalle.balance.cdts.map((c) => <li key={c.id}>CDT: {moneda(c.monto)}</li>)}
            {detalle.balance.creditos.map((c) => <li key={c.id}>Crédito {c.producto}: {moneda(c.saldo)}</li>)}
          </ul>
          <h3>Historial</h3>
          <TransaccionList items={detalle.historial} />
        </section>
      )}
    </>
  );
}
