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
  const [tick, setTick] = useState(0);
  const enVuelo = useRef(false);
  useEffect(() => {
    let vivo = true;
    async function ping() {
      if (enVuelo.current || document.hidden) return;
      enVuelo.current = true;
      try {
        const e = await api<Esquema>('/admin/esquema');
        if (vivo) { setEsquema(e); setConectado(true); setTick((t) => t + 1); }
      } catch (err) {
        if (vivo && (err as Error).name === 'ConexionError') { setConectado(false); setTick((t) => t + 1); }
      } finally { enVuelo.current = false; }
    }
    ping();
    const id = setInterval(ping, PING_MS);
    return () => { vivo = false; clearInterval(id); };
  }, []);
  /** `tick` cambia tras cada ping resuelto: sirve para refrescar la tabla seleccionada al mismo ritmo. */
  return { esquema, conectado, tick };
}

export default function Control() {
  const { esquema, conectado, tick } = usePingEsquema();
  const [filtro, setFiltro] = useState('');
  const [sel, setSel] = useState('');
  const [pagina, setPagina] = useState(1);
  const [datos, setDatos] = useState<PaginaTabla | null>(null);
  const [error, setError] = useState('');

  const cargando = useRef(false);
  const seq = useRef(0);
  function cargar() {
    const id = ++seq.current;
    cargando.current = true;
    api<PaginaTabla>(`/admin/tabla/${encodeURIComponent(sel)}?pagina=${pagina}`).then(
      (d) => { if (id === seq.current) { setDatos(d); setError(''); } },
      (e) => { if (id === seq.current) { setDatos(null); setError(mensaje(e)); } })
      .finally(() => { if (id === seq.current) cargando.current = false; });
  }
  // Al cambiar de tabla/página se carga siempre.
  useEffect(() => {
    if (sel) cargar();
    return () => { seq.current++; cargando.current = false; };
  }, [sel, pagina]); // eslint-disable-line react-hooks/exhaustive-deps
  // En cada ping se refresca la tabla, con el mismo guard (sin solapar y sin pestaña oculta).
  useEffect(() => {
    if (!sel || cargando.current || document.hidden) return;
    cargar();
  }, [tick]); // eslint-disable-line react-hooks/exhaustive-deps

  function elegir(nombre: string) { setSel(nombre); setPagina(1); setDatos(null); }

  return (
    <>
      <h1>Control</h1>
      <p className="estado-conexion">
        Estado:{' '}
        {conectado === null ? 'Verificando…'
          : <strong className={`pill ${conectado ? 'pill-ok' : 'pill-no'}`}>{conectado ? 'CONECTADO' : 'DESCONECTADO'}</strong>}
      </p>
      <label className="buscar">Buscar tabla
        <input value={filtro} onChange={(e) => setFiltro(e.target.value)} />
      </label>
      {esquema && <div className="grafo-wrap"><Grafo tablas={esquema.tablas} filtro={filtro} seleccionada={sel} onSeleccionar={elegir} /></div>}
      {sel && (
        <section className="tabla-datos">
          <h2>{sel}</h2>
          {error && <p role="alert">{error}</p>}
          {datos && conectado !== false && (
            <>
              <div className="tabla-wrap"><table>
                <thead><tr>{datos.columnas.map((c) => <th key={c}>{c}</th>)}</tr></thead>
                <tbody>
                  {datos.filas.map((fila, i) => (
                    <tr key={i}>{datos.columnas.map((c) => <td key={c}>{String(fila[c] ?? '')}</td>)}</tr>
                  ))}
                </tbody>
              </table></div>
              <div className="paginacion">
              <button className="sec" disabled={pagina <= 1} onClick={() => setPagina(pagina - 1)}>Anterior</button>
              <span> Página {datos.pagina} de {datos.total_paginas} </span>
              <button className="sec" disabled={pagina >= datos.total_paginas} onClick={() => setPagina(pagina + 1)}>Siguiente</button>
              </div>
            </>
          )}
        </section>
      )}
    </>
  );
}
