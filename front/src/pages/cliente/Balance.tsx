import { useState } from 'react';
import { api } from '../../api/client';
import { mensaje, useAccion, useCarga } from '../../api/useApi';
import type { Balance as Datos, Bolsillo, Transaccion } from '../../api/types';
import TransaccionList from '../../components/TransaccionList';
import { moneda } from '../../format';

function BolsilloItem({ b, otros, onCambio, onError }: { b: Bolsillo; otros: Bolsillo[]; onCambio: () => void; onError: (m: string) => void }) {
  const [monto, setMonto] = useState('');
  const [destino, setDestino] = useState('');
  const { correr, enVuelo } = useAccion();
  function accion(ruta: string, extra: object = {}) {
    return correr(async () => {
      onError('');
      try {
        await api(`/bolsillos/${b.id}/${ruta}`, { method: 'POST', body: JSON.stringify({ monto: Number(monto), ...extra }) });
        setMonto(''); onCambio();
      } catch (e) { onError(mensaje(e)); }
    });
  }
  return (
    <li data-testid="bolsillo" className="item">
      <span className="item-titulo">{b.nombre}: <strong className="num">{moneda(b.saldo)}</strong></span>
      <span className="item-acciones">
      <input aria-label={`Monto ${b.nombre}`} type="number" value={monto} onChange={(e) => setMonto(e.target.value)} />
      <button onClick={() => accion('ingresar')} disabled={!monto || enVuelo}>Meter</button>
      <button className="sec" onClick={() => accion('retirar')} disabled={!monto || enVuelo}>Sacar</button>
      {otros.length > 0 && (
        <>
          <select aria-label={`Destino ${b.nombre}`} value={destino} onChange={(e) => setDestino(e.target.value)}>
            <option value="">Mover a…</option>
            {otros.map((o) => <option key={o.id} value={String(o.id)}>{o.nombre}</option>)}
          </select>
          <button className="sec" onClick={() => accion('mover', { destino_id: destino })} disabled={!monto || !destino || enVuelo}>Mover</button>
        </>
      )}
      </span>
    </li>
  );
}

export default function Balance() {
  const bal = useCarga<Datos>('/bolsillos');
  const tx = useCarga<Transaccion[]>('/transacciones?limite=50');
  const [nombre, setNombre] = useState('');
  const [error, setError] = useState('');
  const { correr, enVuelo } = useAccion();

  function crear() {
    return correr(async () => {
      setError('');
      try { await api('/bolsillos', { method: 'POST', body: JSON.stringify({ nombre }) }); setNombre(''); bal.recargar(); }
      catch (e) { setError(mensaje(e)); }
    });
  }
  const recargar = () => { bal.recargar(); tx.recargar(); };

  return (
    <>
      <h1>Balance</h1>
      {(error || bal.error) && <p role="alert">{error || bal.error}</p>}
      {bal.data && (
        <>
          <div className="cifras">
            <p>Total: <strong className="num">{moneda(bal.data.total)}</strong></p>
            <p>Principal: <span className="num">{moneda(bal.data.principal)}</span></p>
          </div>
          <h2>Bolsillos</h2>
          <ul className="lista">
            {bal.data.bolsillos.map((b) => (
              <BolsilloItem key={b.id} b={b} otros={bal.data!.bolsillos.filter((o) => o.id !== b.id)} onCambio={recargar} onError={setError} />
            ))}
          </ul>
        </>
      )}
      <div className="panel form fila-form">
      <label>Nuevo bolsillo<input value={nombre} onChange={(e) => setNombre(e.target.value)} /></label>
      <button onClick={crear} disabled={!nombre || enVuelo}>Crear bolsillo</button>
      </div>
      {tx.data && <><h2>Historial</h2><TransaccionList items={tx.data} /></>}
    </>
  );
}
