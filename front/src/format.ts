/** Solo formato de presentación; los valores los calcula el backend. */
export const moneda = (n: number | string) =>
  typeof n === 'number' ? n.toLocaleString('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 2 }) : n;

export const fechaHora = (iso: string) => new Date(iso).toLocaleString('es-CO');

/** La tasa llega como porcentaje efectivo anual (12 = 12% E.A.). Si llega ya como texto, se muestra tal cual. */
export const tasaEA = (t: number | string) => {
  const n = typeof t === 'number' ? t : /^\s*\d+([.,]\d+)?\s*$/.test(t) ? Number(t.replace(',', '.')) : NaN;
  return Number.isFinite(n) ? `${n.toLocaleString('es-CO', { maximumFractionDigits: 2 })}% E.A.` : String(t);
};
