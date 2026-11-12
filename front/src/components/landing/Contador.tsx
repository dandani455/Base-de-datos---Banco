import { useEffect, useState } from 'react';
import { prefiereMenosMovimiento, useReveal } from '../../hooks/useReveal';

interface Props {
  /** Valor final. */
  hasta: number;
  /** Cómo se escribe el número (por defecto con separador de miles colombiano). */
  formato?: (n: number) => string;
  duracion?: number;
  retraso?: number;
  className?: string;
}

const miles = (n: number) => Math.round(n).toLocaleString('es-CO');

/**
 * Cuenta hacia arriba cuando entra en pantalla. Muestra el valor final de entrada si no hay
 * IntersectionObserver o si se pidió reducir el movimiento; el texto accesible siempre es el final.
 */
export default function Contador({ hasta, formato = miles, duracion = 1600, retraso = 0, className }: Props) {
  const { ref, visible } = useReveal<HTMLSpanElement>({ umbral: 0.4, margen: '0px' });
  const animar = typeof IntersectionObserver !== 'undefined' && !prefiereMenosMovimiento();
  const [valor, setValor] = useState(animar ? 0 : hasta);

  useEffect(() => {
    if (!animar) { setValor(hasta); return; }
    if (!visible) return;
    let raf = 0;
    let inicio = 0;
    const paso = (t: number) => {
      if (!inicio) inicio = t;
      const p = Math.min(1, Math.max(0, (t - inicio - retraso) / duracion));
      const e = 1 - Math.pow(1 - p, 4);
      setValor(hasta * e);
      if (p < 1) raf = requestAnimationFrame(paso);
    };
    raf = requestAnimationFrame(paso);
    return () => cancelAnimationFrame(raf);
  }, [visible, animar, hasta, duracion, retraso]);

  return (
    <span ref={ref} className={className}>
      <span aria-hidden="true">{formato(valor)}</span>
      <span className="sr-only">{formato(hasta)}</span>
    </span>
  );
}
