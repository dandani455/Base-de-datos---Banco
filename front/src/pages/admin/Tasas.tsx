import { useEffect, useState } from 'react';
import { api } from '../../api/client';
import { mensaje, useCarga } from '../../api/useApi';
import type { AdminTasas } from '../../api/types';

export default function Tasas() {
  const { data, error, recargar } = useCarga<AdminTasas>('/admin/tasas');
  const [cdts, setCdts] = useState<Record<string, string>>({});
  const [creditos, setCreditos] = useState<Record<string, string>>({});
  const [mora, setMora] = useState('');
  const [err, setErr] = useState('');
  const [ok, setOk] = useState('');

  useEffect(() => {
    if (!data) return;
    setCdts(Object.fromEntries(data.cdts.map((d) => [String(d.id), String(d.tasa)])));
    setCreditos(Object.fromEntries(data.creditos.map((d) => [String(d.id), String(d.tasa)])));
    setMora(String(data.mora));
  }, [data]);

  async function guardar() {
    setErr(''); setOk('');
    try {
      await api('/admin/tasas', { method: 'PUT', body: JSON.stringify({ cdts, creditos, mora }) });
      setOk('Tasas actualizadas'); recargar();
    } catch (e) { setErr(mensaje(e)); }
  }

  return (
    <>
      <h1>Tasas</h1>
      <p>Los productos ya creados no cambian; las nuevas tasas aplican a los futuros.</p>
      {(error || err) && <p role="alert">{error || err}</p>}
      {ok && <p role="status">{ok}</p>}
      {data && (
        <>
          <h2>CDT por definición</h2>
          {data.cdts.map((d) => (
            <label key={d.id}>{d.nombre}
              <input value={cdts[String(d.id)] ?? ''} onChange={(e) => setCdts({ ...cdts, [String(d.id)]: e.target.value })} />
            </label>
          ))}
          <h2>Crédito por producto</h2>
          {data.creditos.map((d) => (
            <label key={d.id}>{d.nombre}
              <input value={creditos[String(d.id)] ?? ''} onChange={(e) => setCreditos({ ...creditos, [String(d.id)]: e.target.value })} />
            </label>
          ))}
          <h2>Mora</h2>
          <label>Tasa de mora<input value={mora} onChange={(e) => setMora(e.target.value)} /></label>
          <button onClick={guardar}>Guardar tasas</button>
        </>
      )}
    </>
  );
}
