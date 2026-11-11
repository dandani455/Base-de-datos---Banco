import { FormEvent, useEffect, useState } from 'react';
import { api } from '../api/client';
import { mensaje, useAccion } from '../api/useApi';
import { moneda } from '../format';

export type CampoSim = { name: string; label: string };
export type ResultadoSim = { clave: string; etiqueta: string };

type Props = {
  titulo: string;
  endpoint: string;
  campos: CampoSim[];
  resultados: ResultadoSim[];
  extra?: Record<string, unknown>;
  accion?: { etiqueta: string; endpoint: string; onHecho?: () => void };
};

/** Pide al backend la simulación y muestra tal cual los valores devueltos (no calcula nada). */
export default function Simulador({ titulo, endpoint, campos, resultados, extra = {}, accion }: Props) {
  const [valores, setValores] = useState<Record<string, string>>({});
  const [res, setRes] = useState<Record<string, number | string> | null>(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const { correr, enVuelo } = useAccion();
  const body = () => JSON.stringify({ ...extra, ...Object.fromEntries(Object.entries(valores).map(([k, v]) => [k, Number(v)])) });

  async function simular(e: FormEvent) {
    e.preventDefault(); setError(''); setOk('');
    try { setRes(await api(endpoint, { method: 'POST', body: body() })); }
    catch (err) { setRes(null); setError(mensaje(err)); }
  }

  // Solo se puede solicitar exactamente lo simulado: si cambia el producto/definición, se descarta el resultado.
  const extraClave = JSON.stringify(extra);
  useEffect(() => { setRes(null); }, [extraClave]);

  function cambiar(name: string, valor: string) {
    setValores({ ...valores, [name]: valor }); setRes(null); setOk('');
  }

  function solicitar() {
    if (!accion) return;
    return correr(async () => {
      setError(''); setOk('');
      try { await api(accion.endpoint, { method: 'POST', body: body() }); setOk('Solicitud realizada'); accion.onHecho?.(); }
      catch (err) { setError(mensaje(err)); }
    });
  }

  return (
    <form onSubmit={simular} aria-label={titulo}>
      <h3>{titulo}</h3>
      {campos.map((c) => (
        <label key={c.name}>{c.label}
          <input type="number" value={valores[c.name] ?? ''} onChange={(e) => cambiar(c.name, e.target.value)} required />
        </label>
      ))}
      <button type="submit">Simular</button>
      {res && (
        <dl>
          {resultados.map((r) => <div key={r.clave}><dt>{r.etiqueta}</dt><dd>{moneda(res[r.clave])}</dd></div>)}
        </dl>
      )}
      {res && accion && <button type="button" onClick={solicitar} disabled={enVuelo}>{accion.etiqueta}</button>}
      {error && <p role="alert">{error}</p>}
      {ok && <p role="status">{ok}</p>}
    </form>
  );
}
