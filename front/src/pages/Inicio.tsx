import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client';

interface Producto { nombre: string; descripcion?: string }

const FALLBACK: Producto[] = [
  { nombre: 'Crédito de libre inversión', descripcion: 'Dinero para lo que necesites, con cuotas fijas.' },
  { nombre: 'Crédito de vivienda', descripcion: 'Financia la casa de tus sueños a largo plazo.' },
  { nombre: 'Crédito de vehículo', descripcion: 'Estrena carro o moto con tasas competitivas.' },
  { nombre: 'Crédito educativo', descripcion: 'Invierte en tu formación y la de tu familia.' },
];

export default function Inicio() {
  const [productos, setProductos] = useState<Producto[]>(FALLBACK);
  useEffect(() => {
    api<Producto[]>('/creditos/productos')
      .then((p) => { if (Array.isArray(p) && p.length) setProductos(p.slice(0, 4)); })
      .catch(() => { /* se mantiene el texto de marketing estático */ });
  }, []);

  return (
    <main>
      <header className="nav">
        <strong>Banco Digital</strong>
        <nav><Link to="/login">Ingresar</Link> <Link to="/registro">Registrarse</Link></nav>
      </header>
      <section className="hero">
        <h1>Banco Digital</h1>
        <p>Tu dinero, simple y seguro, desde cualquier lugar.</p>
        <Link to="/registro">Registrarse</Link> <Link to="/login">Ingresar</Link>
      </section>
      <section>
        <h2>Beneficios</h2>
        <ul>
          <li>Cuenta sin cuota de manejo</li>
          <li>Transferencias inmediatas</li>
          <li>Atención en línea todos los días</li>
        </ul>
      </section>
      <section>
        <h2>Créditos</h2>
        <div className="productos">
          {productos.map((p) => (
            <article key={p.nombre} data-testid="producto">
              <h3>{p.nombre}</h3>
              {p.descripcion && <p>{p.descripcion}</p>}
            </article>
          ))}
        </div>
      </section>
      <section>
        <h2>Sistema de referidos</h2>
        <p>Invita y gana $50.000 por cada amigo que se una a Banco Digital.</p>
      </section>
      <footer>© Banco Digital. Todos los derechos reservados.</footer>
    </main>
  );
}
