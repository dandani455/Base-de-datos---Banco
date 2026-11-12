import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import Foto from './Foto';
import { TarjetaVirtual, useInclinacion } from './landing/Escena';
import type { Zona } from '../imagenes';

interface Props {
  zona: Zona;
  promesa: ReactNode;
  detalle: string;
  puntos: string[];
  children: ReactNode;
}

/**
 * Layout dividido de Ingresar/Registro: panel oscuro sobre la cuadrícula (marca, promesa,
 * foto en el marco común y la tarjeta 3D a su lado) y el formulario a la derecha.
 */
export default function AuthLayout({ zona, promesa, detalle, puntos, children }: Props) {
  const tilt = useInclinacion<HTMLDivElement>(12);
  return (
    <div className="auth-split">
      <aside className="auth-lado">
        <Link to="/" className="marca"><span className="marca-logo" aria-hidden="true"><i /><i /><i /><i /></span>Banco Digital</Link>
        <div className="auth-promesa">
          <p className="auth-titular">{promesa}</p>
          <p className="auth-detalle">{detalle}</p>
        </div>
        <div className="auth-visual">
          <Foto zona={zona} forma="vertical" className="auth-foto" prioridad decorativa />
          <div className="auth-columna">
            <div className="auth-tarjeta" aria-hidden="true">
              <div className="tarjeta-tilt" ref={tilt}><TarjetaVirtual /></div>
            </div>
            <ul className="auth-puntos">
              {puntos.map((p) => <li key={p}>{p}</li>)}
            </ul>
          </div>
        </div>
      </aside>
      {children}
    </div>
  );
}
