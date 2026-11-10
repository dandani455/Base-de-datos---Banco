import { useState } from 'react';
import { api } from '../../api/client';
import { mensaje, useCarga } from '../../api/useApi';
import type { MiCredito, ProductoCredito } from '../../api/types';
import Simulador from '../../components/Simulador';
import { moneda } from '../../format';

function MiCreditoItem({ c, onCambio }: { c: MiCredito; onCambio: () => void }) {
  const [monto, setMonto] = useState('');
  const [error, setError] = useState('');
  async function abonar() {
    setError('');
    try { await api(`/creditos/${c.id}/abono`, { method: 'POST', body: JSON.stringify({ monto: Number(monto) }) }); setMonto(''); onCambio(); }
    catch (e) { setError(mensaje(e)); }
  }
  return (
    <li data-testid="mi-credito">
      <strong>{c.producto}</strong> · Cuotas pagadas: {c.cuotas_pagadas} · Faltantes: {c.cuotas_faltantes} · Interés del mes: {moneda(c.interes_mes)}
      <input aria-label={`Abono ${c.producto}`} type="number" value={monto} onChange={(e) => setMonto(e.target.value)} />
      <button onClick={abonar} disabled={!monto}>Abonar a capital</button>
      {error && <p role="alert">{error}</p>}
    </li>
  );
}

export default function Creditos() {
  const productos = useCarga<ProductoCredito[]>('/creditos/productos');
  const mis = useCarga<MiCredito[]>('/creditos/mis-creditos');
  const [sel, setSel] = useState('');
  const lista = productos.data ?? [];
  const productoId = sel || (lista[0] ? String(lista[0].id) : '');

  return (
    <>
      <h1>Créditos</h1>
      {productos.error && <p role="alert">{productos.error}</p>}
      <ul>
        {lista.map((p) => (
          <li key={p.id} data-testid="producto-credito">
            <strong>{p.nombre}</strong> · Tasa {p.tasa} · Monto {moneda(p.monto_min)} a {moneda(p.monto_max)} · Plazo {p.plazo_min} a {p.plazo_max} meses
          </li>
        ))}
      </ul>
      {lista.length > 0 && (
        <>
          <label>Producto
            <select value={productoId} onChange={(e) => setSel(e.target.value)}>
              {lista.map((p) => <option key={p.id} value={String(p.id)}>{p.nombre}</option>)}
            </select>
          </label>
          <Simulador
            titulo="Simulador de crédito"
            endpoint="/creditos/simular"
            extra={{ producto_id: productoId }}
            campos={[{ name: 'monto', label: 'Monto' }, { name: 'plazo', label: 'Plazo (meses)' }]}
            resultados={[
              { clave: 'cuota_mensual', etiqueta: 'Cuota mensual' },
              { clave: 'total_a_pagar', etiqueta: 'Total a pagar' },
              { clave: 'intereses_totales', etiqueta: 'Intereses totales' },
            ]}
            accion={{ etiqueta: 'Solicitar este crédito', endpoint: '/creditos', onHecho: mis.recargar }}
          />
        </>
      )}
      <h2>Mis créditos</h2>
      {mis.data?.length === 0 && <p>No tienes créditos</p>}
      <ul>{mis.data?.map((c) => <MiCreditoItem key={c.id} c={c} onCambio={mis.recargar} />)}</ul>
    </>
  );
}
