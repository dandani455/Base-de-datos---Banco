import { useState } from 'react';
import { api } from '../api/client';
import { mensaje, useAccion } from '../api/useApi';
import type { Bolsillo, Destinatario } from '../api/types';

export default function EnvioForm({ bolsillos = [], onEnviado }: { bolsillos?: Bolsillo[]; onEnviado?: () => void }) {
  const [numero, setNumero] = useState('');
  const [nombre, setNombre] = useState('');
  const [monto, setMonto] = useState('');
  const [nota, setNota] = useState('');
  const [bolsillo, setBolsillo] = useState('');
  const { correr, enVuelo } = useAccion();
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  async function buscar() {
    setError(''); setOk(''); setNombre('');
    try {
      const d = await api<Destinatario>(`/destinatario/${encodeURIComponent(numero)}`);
      setNombre(d.nombre);
    } catch (e) { setError(mensaje(e)); }
  }

  function confirmar() {
    return correr(async () => {
      setError('');
      try {
        await api('/envios', {
          method: 'POST',
          body: JSON.stringify({
            numero_destino: numero, monto: Number(monto), nota,
            ...(bolsillo ? { bolsillo_origen: bolsillo } : {}),
          }),
        });
        setOk('Envío realizado'); setNombre(''); setNumero(''); setMonto(''); setNota('');
        onEnviado?.();
      } catch (e) { setError(mensaje(e)); }
    });
  }

  return (
    <section aria-label="Enviar dinero">
      <h2>Enviar dinero</h2>
      <label>Número de cuenta destino<input value={numero} onChange={(e) => { setNumero(e.target.value); setNombre(''); }} /></label>
      <button type="button" onClick={buscar} disabled={!numero}>Buscar destinatario</button>
      {nombre && (
        <div>
          <p>¿Envías a {nombre}?</p>
          <label>Monto<input type="number" value={monto} onChange={(e) => setMonto(e.target.value)} /></label>
          <label>Nota<input value={nota} onChange={(e) => setNota(e.target.value)} /></label>
          {bolsillos.length > 0 && (
            <label>Desde
              <select value={bolsillo} onChange={(e) => setBolsillo(e.target.value)}>
                <option value="">Cuenta principal</option>
                {bolsillos.map((b) => <option key={b.id} value={String(b.id)}>{b.nombre}</option>)}
              </select>
            </label>
          )}
          <button type="button" onClick={confirmar} disabled={enVuelo || !monto}>Confirmar envío</button>
        </div>
      )}
      {error && <p role="alert">{error}</p>}
      {ok && <p role="status">{ok}</p>}
    </section>
  );
}
