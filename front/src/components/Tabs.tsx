import { useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';

export interface TabItem { id: string; etiqueta: string; contenido: ReactNode }

interface Props { tabs: TabItem[]; etiqueta: string }

/** Pestañas accesibles (patrón WAI-ARIA): flechas, Inicio/Fin; los paneles inactivos quedan con `hidden`. */
export default function Tabs({ tabs, etiqueta }: Props) {
  const base = useId();
  const [activa, setActiva] = useState(0);
  const botones = useRef<(HTMLButtonElement | null)[]>([]);

  function ir(i: number) {
    const n = (i + tabs.length) % tabs.length;
    setActiva(n);
    botones.current[n]?.focus();
  }
  function teclado(e: KeyboardEvent<HTMLDivElement>) {
    const mapa: Record<string, number | undefined> = {
      ArrowRight: activa + 1, ArrowLeft: activa - 1, Home: 0, End: tabs.length - 1,
    };
    const destino = mapa[e.key];
    if (destino === undefined) return;
    e.preventDefault();
    ir(destino);
  }

  return (
    <div className="tabs">
      <div className="tabs-lista" role="tablist" aria-label={etiqueta} onKeyDown={teclado}>
        {tabs.map((t, i) => (
          <button
            key={t.id}
            ref={(el) => { botones.current[i] = el; }}
            type="button"
            role="tab"
            id={`${base}-tab-${t.id}`}
            aria-selected={i === activa}
            aria-controls={`${base}-panel-${t.id}`}
            tabIndex={i === activa ? 0 : -1}
            className="tabs-tab"
            onClick={() => setActiva(i)}
          >
            {t.etiqueta}
          </button>
        ))}
      </div>
      {tabs.map((t, i) => (
        <div
          key={t.id}
          role="tabpanel"
          id={`${base}-panel-${t.id}`}
          aria-labelledby={`${base}-tab-${t.id}`}
          hidden={i !== activa}
          tabIndex={0}
          className="tabs-panel"
        >
          {t.contenido}
        </div>
      ))}
    </div>
  );
}
