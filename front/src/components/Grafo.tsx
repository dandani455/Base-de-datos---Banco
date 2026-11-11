import type { EsquemaTabla } from '../api/types';

const ANCHO = 190, ALTO_CAB = 26, ALTO_COL = 15, GAP_X = 50, GAP_Y = 40;

type Nodo = { t: EsquemaTabla; x: number; y: number; h: number };

/** Layout en cuadrícula calculado solo desde el esquema (sin librería de grafos). */
export function calcularLayout(tablas: EsquemaTabla[]): { nodos: Nodo[]; w: number; h: number } {
  const cols = Math.max(1, Math.ceil(Math.sqrt(tablas.length)));
  const nodos: Nodo[] = [];
  let y = 10, maxW = 0;
  for (let i = 0; i < tablas.length; i += cols) {
    const fila = tablas.slice(i, i + cols);
    const altoFila = Math.max(...fila.map((t) => ALTO_CAB + t.columnas.length * ALTO_COL + 6));
    fila.forEach((t, j) => nodos.push({ t, x: 10 + j * (ANCHO + GAP_X), y, h: ALTO_CAB + t.columnas.length * ALTO_COL + 6 }));
    maxW = Math.max(maxW, 10 + fila.length * (ANCHO + GAP_X));
    y += altoFila + GAP_Y;
  }
  return { nodos, w: maxW, h: y };
}

const badges = (c: EsquemaTabla['columnas'][number]) =>
  [c.llave && 'PK', c.unico && 'UQ', c.no_nulo && 'NN'].filter(Boolean).join(' ');

type Props = { tablas: EsquemaTabla[]; filtro: string; seleccionada: string; onSeleccionar: (nombre: string) => void };

export default function Grafo({ tablas, filtro, seleccionada, onSeleccionar }: Props) {
  const { nodos, w, h } = calcularLayout(tablas);
  const por = new Map(nodos.map((n) => [n.t.nombre, n]));
  const f = filtro.trim().toLowerCase();
  const visible = (n: string) => !f || n.toLowerCase().includes(f);

  return (
    <svg className="grafo" viewBox={`0 0 ${w} ${h}`} width="100%" role="img" aria-label="Grafo de tablas y relaciones">
      {nodos.flatMap(({ t, x, y }) =>
        t.fks.map((fk) => {
          const d = por.get(fk.tabla_destino);
          if (!d) return null;
          return (
            <line key={`${t.nombre}.${fk.columna}`} data-testid="arista" className="g-arista"
              opacity={visible(t.nombre) || visible(fk.tabla_destino) ? 1 : 0.15}
              x1={x + ANCHO / 2} y1={y + 10} x2={d.x + ANCHO / 2} y2={d.y + 10} />
          );
        }))}
      {nodos.map(({ t, x, y, h: alto }) => (
        <g key={t.nombre} className={seleccionada === t.nombre ? 'g-nodo sel' : 'g-nodo'} role="button" tabIndex={0} aria-label={`Tabla ${t.nombre}`}
          opacity={visible(t.nombre) ? 1 : 0.25}
          onClick={() => onSeleccionar(t.nombre)}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') onSeleccionar(t.nombre); }}>
          <rect x={x} y={y} width={ANCHO} height={alto} rx={6} />
          <text x={x + 8} y={y + 17} className="g-titulo">{t.nombre}</text>
          {t.columnas.map((c, i) => (
            <text key={c.nombre} className="g-col" x={x + 8} y={y + ALTO_CAB + 11 + i * ALTO_COL} >
              {c.nombre}<tspan x={x + ANCHO - 8} textAnchor="end" className="g-badge">{badges(c)}</tspan>
            </text>
          ))}
        </g>
      ))}
    </svg>
  );
}
