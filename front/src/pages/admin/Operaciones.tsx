import { useState } from 'react';
import { api } from '../../api/client';
import { mensaje } from '../../api/useApi';

export default function Operaciones() {
  const [usuario, setUsuario] = useState('');
  const [monto, setMonto] = useState('');
  const [nota, setNota] = useState('');
  const [err, setErr] = useState('');
  const [ok, setOk] = useState('');

  async function enviar(e: React.FormEvent) {
    e.preventDefault(); setErr(''); setOk('');
    try {
      await api('/admin/balance', { method: 'POST', body: JSON.stringify({ usuario_id: usuario, monto: Number(monto), nota }) });
      setOk('Balance añadido'); setMonto(''); setNota('');
    } catch (e2) { setErr(mensaje(e2)); }
  }

  return (
    <>
      <h1>Operaciones</h1>
      <form onSubmit={enviar}>
        <label>Usuario (id)<input value={usuario} onChange={(e) => setUsuario(e.target.value)} required /></label>
        <label>Monto<input type="number" step="any" value={monto} onChange={(e) => setMonto(e.target.value)} required /></label>
        <label>Nota<input value={nota} onChange={(e) => setNota(e.target.value)} /></label>
        <button type="submit">Añadir balance</button>
      </form>
      {err && <p role="alert">{err}</p>}
      {ok && <p role="status">{ok}</p>}
    </>
  );
}
