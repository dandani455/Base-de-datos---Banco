import { useState } from 'react';
import { useCarga } from '../../api/useApi';
import type { DefinicionCdt, MiCdt } from '../../api/types';
import Simulador from '../../components/Simulador';
import { fechaHora, moneda } from '../../format';

export default function Cdts() {
  const defs = useCarga<DefinicionCdt[]>('/cdts/definiciones');
  const mis = useCarga<MiCdt[]>('/cdts');
  const [sel, setSel] = useState('');
  const lista = defs.data ?? [];
  const definicionId = sel || (lista[0] ? String(lista[0].id) : '');

  return (
    <>
      <h1>CDTs</h1>
      {defs.error && <p role="alert">{defs.error}</p>}
      <ul className="lista">
        {lista.map((d) => (
          <li key={d.id} data-testid="definicion-cdt" className="item">
            <strong>{d.nombre}</strong> · Tasa {d.tasa} · {d.plazo_dias} días · Mínimo {moneda(d.monto_min)}
          </li>
        ))}
      </ul>
      {lista.length > 0 && (
        <>
          <label className="selector">Definición
            <select value={definicionId} onChange={(e) => setSel(e.target.value)}>
              {lista.map((d) => <option key={d.id} value={String(d.id)}>{d.nombre}</option>)}
            </select>
          </label>
          <Simulador
            titulo="Simulador de CDT"
            endpoint="/cdts/simular"
            extra={{ definicion_id: definicionId }}
            campos={[{ name: 'monto', label: 'Monto' }]}
            resultados={[
              { clave: 'generado_mes', etiqueta: 'Generado al mes' },
              { clave: 'generado_dia', etiqueta: 'Generado al día' },
              { clave: 'generado_vencimiento', etiqueta: 'Generado al vencimiento' },
            ]}
            accion={{ etiqueta: 'Crear CDT', endpoint: '/cdts', onHecho: mis.recargar }}
          />
        </>
      )}
      <h2>Mis CDT</h2>
      {mis.data?.length === 0 && <p className="vacio">No tienes CDTs</p>}
      <ul className="lista">
        {mis.data?.map((c) => (
          <li key={c.id} data-testid="mi-cdt" className="item">
            Monto {moneda(c.monto)} · Generado hasta hoy {moneda(c.generado_hasta_hoy)} · Tiempo restante {c.tiempo_restante} · Cierre {fechaHora(c.fecha_cierre)}
          </li>
        ))}
      </ul>
    </>
  );
}
