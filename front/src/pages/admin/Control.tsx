import { useEffect, useRef, useState } from 'react';
import { api } from '../../api/client';
import { mensaje } from '../../api/useApi';
import type { Esquema, PaginaTabla } from '../../api/types';
import Grafo from '../../components/Grafo';

const PING_MS = 5000;

/** Ping a /admin/esquema: sin solapar peticiones y en pausa con la pestaña oculta. */
function usePingEsquema() {
  const [esquema, setEsquema] = useState<Esquema | null>(null);
  const [conectado, setConectado] = useState<boolean | null>(null);
  const enVuelo = useRef(false);
  useEffect(() => {
    let vivo = true;
    async function ping() {
      if (enVuelo.current || document.hidden) return;
      enVuelo.current = true;
      try {
        const e = await api<Esquema>('/admin/esquema');
        if (vivo) { setEsquema(e); setConectado(true); }
      } catch (err) {
        if (vivo && (err as Error).name === 'ConexionError') setConectado(false);
      } finally { enVuelo.current = false; }
    }
    ping();
    const id = setInterval(ping, PING_MS);
    return () => { vivo = false; clearInterval(id); };
  }, []);
  return { esquema, conectado };
}

export default function Control() {
  const { esquema, conectado } = usePingEsquema();
  const [filtro, setFiltro] = useState('');
  const [sel, setSel] = useState('');
  const [pagina, setPagina] = useState(1);
  const [datos, setDatos] = useState<PaginaTabla | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!sel) return;
    let vivo = true;
    api<PaginaTabla>(`/admin/tabla/${encodeURIComponent(sel)}?pagina=${pagina}`).then(
      (d) => { if (vivo) { setDatos(d); setError(''); } },
      (e) => { if (vivo) setError(mensaje(e)); });
    return () => { vivo = false; };
  }, [sel, pagina]);

  function elegir(nombre: string) { setSel(nombre); setPagina(1); setDatos(null); }

  return (
    <>
      <h1>Control</h1>
      <p>
        Estado:{' '}
        {conectado === null ? 'Verificando…'
          : <strong style={{ color: conectado ? 'green' : 'red' }}>{conectado ? 'CONECTADO' : 'DESCONECTADO'}</strong>}
      </p>
      <label>Buscar tabla
        <input value={filtro} onChange={(e) => setFiltro(e.target.value)} />
      </label>
      {esquema && <Grafo tablas={esquema.tablas} filtro={filtro} seleccionada={sel} onSeleccionar={elegir} />}
      {sel && (
        <section>
          <h2>{sel}</h2>
          {error && <p role="alert">{error}</p>}
          {datos && (
            <>
              <table>
                <thead><tr>{datos.columnas.map((c) => <th key={c}>{c}</th>)}</tr></thead>
                <tbody>
                  {datos.filas.map((fila, i) => (
                    <tr key={i}>{datos.columnas.map((c) => <td key={c}>{String(fila[c] ?? '')}</td>)}</tr>
                  ))}
                </tbody>
              </table>
              <button disabled={pagina <= 1} onClick={() => setPagina(pagina - 1)}>Anterior</button>
              <span> Página {datos.pagina} de {datos.total_paginas} </span>
              <button disabled={pagina >= datos.total_paginas} onClick={() => setPagina(pagina + 1)}>Siguiente</button>
            </>
          )}
        </section>
      )}
    </>
  );
}
