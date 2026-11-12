import { useEffect, useRef } from 'react';
import { prefiereMenosMovimiento } from '../../hooks/useReveal';
import Contador from './Contador';

/**
 * Piezas decorativas de la landing. Todo lo que hay aquí es un EJEMPLO ilustrativo
 * (sin datos reales ni lógica): por eso cada escena va dentro de un contenedor aria-hidden.
 */

const pesos = (n: number) => '$' + Math.round(n).toLocaleString('es-CO');

/** Tarjeta débito virtual con brillo holográfico. La inclinación la controla quien la usa (variables --rx/--ry). */
export function TarjetaVirtual({ className = '' }: { className?: string }) {
  return (
    <div className={`tarjeta ${className}`}>
      <span className="tarjeta-brillo" />
      <span className="tarjeta-arriba">
        <span className="tarjeta-marca">Banco Digital</span>
        <span className="tarjeta-tipo">Débito</span>
      </span>
      <span className="tarjeta-medio">
        <span className="tarjeta-chip" />
        <svg className="tarjeta-nfc" viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <path d="M8.5 7.5a6 6 0 0 1 0 9M12 5a9.5 9.5 0 0 1 0 14M15.5 2.5a13 13 0 0 1 0 19" />
        </svg>
      </span>
      <span className="tarjeta-num">•••• •••• •••• 4821</span>
      <span className="tarjeta-abajo">
        <span>Laura Gómez</span>
        <span>12/30</span>
      </span>
    </div>
  );
}

/** Inclina un elemento hacia el puntero (solo ratón, sin movimiento reducido, con rAF). */
export function useInclinacion<T extends HTMLElement>(fuerza = 14) {
  const ref = useRef<T | null>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || prefiereMenosMovimiento()) return;
    if (window.matchMedia('(hover: none), (pointer: coarse)').matches) return;
    let raf = 0;
    let x = 0;
    let y = 0;
    const aplicar = () => {
      raf = 0;
      const r = el.getBoundingClientRect();
      const dx = Math.max(-1, Math.min(1, (x - (r.left + r.width / 2)) / (window.innerWidth / 2)));
      const dy = Math.max(-1, Math.min(1, (y - (r.top + r.height / 2)) / (window.innerHeight / 2)));
      el.style.setProperty('--ry', `${(dx * fuerza).toFixed(2)}deg`);
      el.style.setProperty('--rx', `${(-dy * fuerza * 0.8).toFixed(2)}deg`);
      el.style.setProperty('--mx', `${(50 + dx * 50).toFixed(1)}%`);
    };
    const mover = (e: PointerEvent) => {
      if (e.pointerType !== 'mouse') return;
      x = e.clientX;
      y = e.clientY;
      if (!raf) raf = requestAnimationFrame(aplicar);
    };
    window.addEventListener('pointermove', mover, { passive: true });
    return () => { window.removeEventListener('pointermove', mover); cancelAnimationFrame(raf); };
  }, [fuerza]);
  return ref;
}

const MOVS = [
  { nombre: 'Nómina', detalle: 'Recibido · hoy', monto: '+$3.200.000', tipo: 'entra' },
  { nombre: 'Bolsillo Viajes', detalle: 'Rendimiento diario', monto: '+$1.284', tipo: 'entra' },
  { nombre: 'Arriendo', detalle: 'Transferencia · ayer', monto: '-$1.150.000', tipo: 'sale' },
];

/** Escena del hero: teléfono con la app, tarjeta 3D y chips flotantes. Decorativa. */
export function EscenaHero() {
  const tilt = useInclinacion<HTMLDivElement>(16);
  return (
    <div className="escena" aria-hidden="true">
      <div className="escena-halo" />
      <div className="telefono">
        <div className="tel-marco">
          <div className="tel-pantalla">
            <div className="tel-estado"><span>9:41</span><span className="tel-isla" /><span className="tel-senal" /></div>
            <div className="tel-cabeza">
              <span className="tel-avatar">LG</span>
              <span><small>Buenos días</small><strong>Laura</strong></span>
              <span className="tel-ejemplo">Ejemplo</span>
            </div>
            <div className="tel-saldo">
              <small>Saldo disponible</small>
              <Contador hasta={4826350} formato={pesos} retraso={700} duracion={1800} className="tel-monto" />
              <span className="tel-subida">▲ 2,4% este mes</span>
              <svg className="tel-chispa" viewBox="0 0 240 64" preserveAspectRatio="none">
                <defs>
                  <linearGradient id="chispa-relleno" x1="0" x2="0" y1="0" y2="1">
                    <stop offset="0" stopColor="#22D3C5" stopOpacity=".45" />
                    <stop offset="1" stopColor="#22D3C5" stopOpacity="0" />
                  </linearGradient>
                </defs>
                <path className="chispa-area" d="M0 52 L20 48 L40 50 L60 40 L80 43 L100 34 L120 37 L140 26 L160 29 L180 18 L200 21 L220 10 L240 6 L240 64 L0 64 Z" fill="url(#chispa-relleno)" />
                <path className="chispa-linea" pathLength={1} d="M0 52 L20 48 L40 50 L60 40 L80 43 L100 34 L120 37 L140 26 L160 29 L180 18 L200 21 L220 10 L240 6" fill="none" stroke="#22D3C5" strokeWidth="2.5" strokeLinejoin="round" strokeLinecap="round" />
                <circle cx="240" cy="6" r="4" fill="#22D3C5" className="chispa-punto" />
              </svg>
            </div>
            <div className="tel-acciones">
              <span><i>↗</i>Enviar</span><span><i>◔</i>Bolsillos</span><span><i>▤</i>CDT</span>
            </div>
            <ul className="tel-movs">
              {MOVS.map((m) => (
                <li key={m.nombre} className={`tel-mov ${m.tipo}`}>
                  <span className="tel-mov-ico">{m.tipo === 'entra' ? '+' : '−'}</span>
                  <span className="tel-mov-txt"><b>{m.nombre}</b><small>{m.detalle}</small></span>
                  <span className="tel-mov-monto">{m.monto}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>
      <div className="tarjeta-flota">
        <div className="tarjeta-tilt" ref={tilt}>
          <TarjetaVirtual />
        </div>
      </div>
      <span className="chip chip-1"><i className="chip-ico sun">$</i>+$50.000 bono de referido</span>
      <span className="chip chip-2"><i className="chip-ico teal">%</i>12% E.A. en tus bolsillos</span>
      <span className="chip chip-3"><i className="chip-ico coral">⚡</i>Desembolso inmediato</span>
    </div>
  );
}
