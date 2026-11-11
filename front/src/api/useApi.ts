import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from './client';

/** Mensaje para mostrar; vacío si es pérdida de conexión (la maneja el banner global). */
export function mensaje(err: unknown): string {
  const e = err as Error;
  return e.name === 'ConexionError' ? '' : e.message;
}

/** GET que se carga al montar. Sin datos mientras falla (503 → solo banner). */
export function useCarga<T>(path: string) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState('');
  const recargar = useCallback(() => {
    api<T>(path).then((d) => { setData(d); setError(''); }, (e) => { setData(null); setError(mensaje(e)); });
  }, [path]);
  useEffect(recargar, [recargar]);
  return { data, error, recargar };
}

/** Acción de una sola petición a la vez (anti doble clic): `correr` ignora llamadas mientras hay una en vuelo. */
export function useAccion() {
  const bloqueo = useRef(false);
  const [enVuelo, setEnVuelo] = useState(false);
  const correr = useCallback(async (fn: () => Promise<void>) => {
    if (bloqueo.current) return;
    bloqueo.current = true; setEnVuelo(true);
    try { await fn(); } finally { bloqueo.current = false; setEnVuelo(false); }
  }, []);
  return { correr, enVuelo };
}
