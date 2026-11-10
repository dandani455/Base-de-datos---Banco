import { useState } from 'react';
import { api } from '../../api/client';
import { mensaje, useCarga } from '../../api/useApi';
import type { Balance as Datos, Bolsillo, Transaccion } from '../../api/types';
import TransaccionList from '../../components/TransaccionList';
import { moneda } from '../../format';

function BolsilloItem({ b, otros, onCambio, onError }: { b: Bolsillo; otros: Bolsillo[]; onCambio: () => void; onError: (m: string) => void }) {
  const [monto, setMonto] = useState('');
  const [destino, setDestino] = useState('');
  async function accion(ruta: string, extra: object = {}) {
    onError('');
    try {
      await api(`/bolsillos/${b.id}/${ruta}`, { method: 'POST', body: JSON.stringify({ monto: Number(monto), ...extra }) });
      setMonto(''); onCambio();
    } catch (e) { onError(mensaje(e)); }
  }
  return (
    <li data-testid="bolsillo">
      {b.nombre}: {moneda(b.saldo)}
      <input aria-label={`Monto ${b.nombre}`} type="number" value={monto} onChange={(e) => setMonto(e.target.value)} />
      <button onClick={() => accion('ingresar')} disabled={!monto}>Meter</button>
      <button onClick={() => accion('retirar')} disabled={!monto}>Sacar</button>
      {otros.length > 0 && (
        <>
          <select aria-label={`Destino ${b.nombre}`} value={destino} onChange={(e) => setDestino(e.target.value)}>
            <option value="">Mover a…</option>
            {otros.map((o) => <option key={o.id} value={String(o.id)}>{o.nombre}</option>)}
          </select>
          <button onClick={() => accion('mover', { destino_id: destino })} disabled={!monto || !destino}>Mover</button>
        </>
      )}
    </li>
  );
}

export default function Balance() {
  const bal = useCarga<Datos>('/bolsillos');
  const tx = useCarga<Transaccion[]>('/transacciones?limite=50');
  const [nombre, setNombre] = useState('');
  const [error, setError] = useState('');

  async function crear() {
    setError('');
    try { await api('/bolsillos', { method: 'POST', body: JSON.stringify({ nombre }) }); setNombre(''); bal.recargar(); }
    catch (e) { setError(mensaje(e)); }
  }
  const recargar = () => { bal.recargar(); tx.recargar(); };

  return (
    <>
      <h1>Balance</h1>
      {(error || bal.error) && <p role="alert">{error || bal.error}</p>}
      {bal.data && (
        <>
          <p>Total: <strong>{moneda(bal.data.total)}</strong></p>
          <p>Principal: {moneda(bal.data.principal)}</p>
          <h2>Bolsillos</h2>
          <ul>
            {bal.data.bolsillos.map((b) => (
              <BolsilloItem key={b.id} b={b} otros={bal.data!.bolsillos.filter((o) => o.id !== b.id)} onCambio={recargar} onError={setError} />
            ))}
          </ul>
        </>
      )}
      <label>Nuevo bolsillo<input value={nombre} onChange={(e) => setNombre(e.target.value)} /></label>
      <button onClick={crear} disabled={!nombre}>Crear bolsillo</button>
      {tx.data && <><h2>Historial</h2><TransaccionList items={tx.data} /></>}
    </>
  );
}
