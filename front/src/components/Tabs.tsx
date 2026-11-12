import { useId, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from 'react';

export interface TabItem { id: string; etiqueta: string; contenido: ReactNode }

interface Props { tabs: TabItem[]; etiqueta: string }

/** Pestañas accesibles (patrón WAI-ARIA): flechas, Inicio/Fin; los paneles inactivos quedan con `hidden`. */
export default function Tabs({ tabs, etiqueta }: Props) {
  const base = useId();
  const [activa, setActiva] = useState(0);
  const botones = useRef<(HTMLButtonElement | null)[]>([]);
  const [indicador, setIndicador] = useState<CSSProperties>({ opacity: 0 });

  // Indicador deslizante bajo la pestaña activa (decorativo); se recalcula al cambiar o redimensionar.
  useLayoutEffect(() => {
    const medir = () => {
      const b = botones.current[activa];
      if (!b || !b.offsetWidth) return;
      setIndicador({ width: b.offsetWidth, height: b.offsetHeight, transform: `translate(${b.offsetLeft}px, ${b.offsetTop}px)`, opacity: 1 });
      const lista = b.parentElement;
      if (lista && lista.scrollWidth > lista.clientWidth) lista.scrollLeft = Math.max(0, b.offsetLeft - 16);
    };
    medir();
    // Las fuentes web cambian el ancho de las pestañas al cargar: se vuelve a medir.
    document.fonts?.ready.then(medir).catch(() => {});
    const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(medir) : null;
    const lista = botones.current[0]?.parentElement;
    if (ro && lista) ro.observe(lista);
    window.addEventListener('resize', medir);
    return () => { window.removeEventListener('resize', medir); ro?.disconnect(); };
  }, [activa]);

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
        <span className="tabs-indicador" aria-hidden="true" style={indicador} />
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
