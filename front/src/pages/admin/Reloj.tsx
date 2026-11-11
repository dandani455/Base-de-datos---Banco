import { useEffect, useState } from 'react';
import { api } from '../../api/client';
import { mensaje, useCarga } from '../../api/useApi';
import type { AdminReloj } from '../../api/types';

export default function Reloj() {
  const { data, error, recargar } = useCarga<AdminReloj>('/admin/reloj');
  const [real, setReal] = useState(true);
  const [fecha, setFecha] = useState('');
  const [err, setErr] = useState('');
  const [ok, setOk] = useState('');

  useEffect(() => {
    if (data) { setReal(data.usar_fecha_real); setFecha((data.fecha_sistema ?? '').slice(0, 10)); }
  }, [data]);

  const minimo = data?.fecha_actual.slice(0, 10) ?? '';
  const invalida = !real && (!fecha || fecha < minimo); // solo adelantar

  async function guardar() {
    setErr(''); setOk('');
    try {
      await api('/admin/reloj', { method: 'PUT', body: JSON.stringify({ usar_fecha_real: real, fecha_sistema: fecha }) });
      setOk('Reloj actualizado'); recargar();
    } catch (e) { setErr(mensaje(e)); }
  }

  return (
    <>
      <h1>Reloj</h1>
      {(error || err) && <p role="alert">{error || err}</p>}
      {ok && <p role="status">{ok}</p>}
      {data && (
        <>
          <div className="panel form">
          <p>Fecha actual del sistema: {data.fecha_actual.slice(0, 10)}</p>
          <label className="check"><input type="checkbox" checked={real} onChange={(e) => setReal(e.target.checked)} /> Usar fecha real</label>
          <label>Fecha del sistema
            <input type="date" value={fecha} min={minimo} disabled={real} onChange={(e) => setFecha(e.target.value)} />
          </label>
          <button disabled={invalida} onClick={guardar}>Guardar</button>
          </div>
        </>
      )}
    </>
  );
}
