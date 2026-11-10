import { useCallback, useEffect, useState } from 'react';
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
    api<T>(path).then((d) => { setData(d); setError(''); }, (e) => setError(mensaje(e)));
  }, [path]);
  useEffect(recargar, [recargar]);
  return { data, error, recargar };
}
