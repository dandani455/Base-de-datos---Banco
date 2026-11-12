import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import Foto from './Foto';
import { TarjetaVirtual, useInclinacion } from './landing/Escena';
import type { Zona } from '../imagenes';

interface Props {
  zona: Zona;
  promesa: ReactNode;
  detalle: string;
  children: ReactNode;
}

/**
 * Layout dividido de Ingresar/Registro: panel oscuro sobre la cuadrícula con la marca, el titular
 * y dos columnas iguales: la foto (marco común) y, a su lado, una línea de texto arriba y la
 * tarjeta 3D abajo, alineadas a los bordes de la foto. El formulario va a la derecha.
 */
export default function AuthLayout({ zona, promesa, detalle, children }: Props) {
  const tilt = useInclinacion<HTMLDivElement>(12);
  return (
    <div className="auth-split">
      <aside className="auth-lado">
        <Link to="/" className="marca"><span className="marca-logo" aria-hidden="true"><i /><i /><i /><i /></span>Banco Digital</Link>
        <p className="auth-titular">{promesa}</p>
        <div className="auth-visual">
          <Foto zona={zona} forma="vertical" className="auth-foto" prioridad decorativa />
          <div className="auth-columna">
            <p className="auth-detalle">{detalle}</p>
            <div className="auth-tarjeta" aria-hidden="true">
              <div className="tarjeta-tilt" ref={tilt}><TarjetaVirtual /></div>
            </div>
          </div>
        </div>
      </aside>
      {children}
    </div>
  );
}
