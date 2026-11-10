/** Solo formato de presentación; los valores los calcula el backend. */
export const moneda = (n: number | string) =>
  typeof n === 'number' ? n.toLocaleString('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 2 }) : n;

export const fechaHora = (iso: string) => new Date(iso).toLocaleString('es-CO');
