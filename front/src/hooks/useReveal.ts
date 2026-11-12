import { useCallback, useEffect, useRef, useState } from 'react';

/** true si el usuario pidió reducir el movimiento (o si no hay matchMedia, como en jsdom). */
export function prefiereMenosMovimiento(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return true;
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/**
 * Revelado al hacer scroll: añade `is-visible` una sola vez cuando el elemento entra en pantalla.
 * Sin IntersectionObserver (jsdom, navegadores viejos) el elemento se marca visible de inmediato.
 * El contenido es visible por defecto: el CSS solo lo oculta bajo `html.js`.
 */
export function useReveal<T extends Element = HTMLElement>(opciones?: { margen?: string; umbral?: number }) {
  const [visible, setVisible] = useState(false);
  const nodo = useRef<T | null>(null);
  const obs = useRef<IntersectionObserver | null>(null);
  const margen = opciones?.margen ?? '0px 0px -12% 0px';
  const umbral = opciones?.umbral ?? 0.12;

  const ref = useCallback((el: T | null) => {
    obs.current?.disconnect();
    obs.current = null;
    nodo.current = el;
    if (!el) return;
    if (el.classList.contains('is-visible')) return;
    if (typeof IntersectionObserver === 'undefined') {
      el.classList.add('is-visible');
      setVisible(true);
      return;
    }
    const io = new IntersectionObserver((entradas) => {
      for (const e of entradas) {
        if (e.isIntersecting) {
          e.target.classList.add('is-visible');
          setVisible(true);
          io.disconnect();
        }
      }
    }, { rootMargin: margen, threshold: umbral });
    io.observe(el);
    obs.current = io;
  }, [margen, umbral]);

  useEffect(() => () => obs.current?.disconnect(), []);
  return { ref, visible };
}
