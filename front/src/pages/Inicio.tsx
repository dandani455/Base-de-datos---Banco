import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client';
import Tabs from '../components/Tabs';
import { IMAGENES, imagen, rutaImagen, type Zona } from '../imagenes';

interface Producto { nombre: string; descripcion?: string }

const FALLBACK: Producto[] = [
  { nombre: 'Crédito de libre inversión', descripcion: 'Dinero para lo que necesites, con cuotas fijas.' },
  { nombre: 'Crédito de vivienda', descripcion: 'Financia la casa de tus sueños a largo plazo.' },
  { nombre: 'Crédito de vehículo', descripcion: 'Estrena carro o moto con tasas competitivas.' },
  { nombre: 'Crédito educativo', descripcion: 'Invierte en tu formación y la de tu familia.' },
];

/** Foto de una zona, siempre desde el registro. El hero se carga con prioridad; el resto en diferido. */
function Foto({ zona, className, prioridad = false }: { zona: Zona; className?: string; prioridad?: boolean }) {
  const img = imagen(zona);
  return (
    <img
      className={className}
      src={rutaImagen(img)}
      alt={img.alt}
      width={img.ancho}
      height={img.alto}
      {...(prioridad ? { fetchPriority: 'high' as const } : { loading: 'lazy' as const })}
      decoding="async"
    />
  );
}

function PanelTab({ zona, titulo, children }: { zona: Zona; titulo: string; children: React.ReactNode }) {
  return (
    <div className="panel-tab">
      <div className="panel-texto">
        <h3>{titulo}</h3>
        {children}
        <Link to="/registro" className="enlace-flecha">Abrir mi cuenta</Link>
      </div>
      <Foto zona={zona} className="panel-foto" />
    </div>
  );
}

export default function Inicio() {
  const [productos, setProductos] = useState<Producto[]>(FALLBACK);
  useEffect(() => {
    api<Producto[]>('/creditos/productos')
      .then((p) => { if (Array.isArray(p) && p.length) setProductos(p.slice(0, 4)); })
      .catch(() => { /* se mantiene el texto de marketing estático */ });
  }, []);

  const tabs = [
    {
      id: 'bolsillos', etiqueta: 'Cuenta y bolsillos',
      contenido: (
        <PanelTab zona="tab-bolsillos" titulo="Tu cuenta, dividida a tu manera">
          <p>Cada bolsillo rinde 12% E.A., pagado todos los días. Puedes abrir varios para separar lo que ahorras de lo que gastas.</p>
        </PanelTab>
      ),
    },
    {
      id: 'cdt', etiqueta: 'CDT',
      contenido: (
        <PanelTab zona="tab-cdt" titulo="CDT a tu medida">
          <p>Eliges el monto y el plazo. La rentabilidad se acumula todos los días y el dinero queda quieto hasta el vencimiento: no hay retiro anticipado.</p>
        </PanelTab>
      ),
    },
    {
      id: 'creditos', etiqueta: 'Créditos',
      contenido: (
        <div className="panel-tab">
          <div className="panel-texto">
            <h3>Dinero cuando lo necesitas</h3>
            <p>El desembolso es inmediato y las cuotas se calculan con amortización francesa. Si haces abonos a capital, la cuota baja.</p>
            <div className="productos">
              {productos.map((p) => (
                <article key={p.nombre} data-testid="producto">
                  <h4>{p.nombre}</h4>
                  {p.descripcion && <p>{p.descripcion}</p>}
                </article>
              ))}
            </div>
          </div>
          <Foto zona="tab-creditos" className="panel-foto" />
        </div>
      ),
    },
    {
      id: 'referidos', etiqueta: 'Referidos',
      contenido: (
        <PanelTab zona="tab-referidos" titulo="Sistema de referidos">
          <p>Invita y gana $50.000 COP por cada amigo que se una a Banco Digital.</p>
        </PanelTab>
      ),
    },
  ];

  const creditos = [...new Set(IMAGENES.map((i) => i.fotografo))];

  return (
    <div className="landing">
      <header className="nav">
        <div className="nav-in">
          <a href="#inicio" className="marca">Banco Digital</a>
          <nav aria-label="Secciones" className="nav-sec">
            <a href="#beneficios">Beneficios</a>
            <a href="#productos">Productos</a>
            <a href="#pasos">Cómo empezar</a>
            <a href="#seguridad">Seguridad</a>
          </nav>
          <nav aria-label="Cuenta" className="nav-cta">
            <Link to="/login" className="nav-ingresar">Ingresar</Link>
            <Link to="/registro" className="btn btn-sun">Registrarse</Link>
          </nav>
        </div>
      </header>

      <main id="inicio">
        <section className="hero" aria-labelledby="hero-t">
          <Foto zona="hero" className="hero-foto" prioridad />
          <div className="hero-velo" />
          <div className="hero-in">
            <h1 id="hero-t">Banco Digital</h1>
            <p className="hero-lema">Tu dinero, simple y seguro, desde cualquier lugar.</p>
            <p className="hero-sub">Abre tu cuenta con tu cédula, ahorra con 12% E.A. pagado cada día y pide créditos con desembolso inmediato.</p>
            <div className="hero-acciones">
              <Link to="/registro" className="btn btn-sun">Registrarse</Link>
              <Link to="/login" className="btn btn-claro">Ingresar</Link>
            </div>
          </div>
        </section>

        <section className="sec sec-surface" id="beneficios" aria-labelledby="ben-t">
          <div className="sec-in">
            <h2 id="ben-t">Un banco que no te cobra por tenerlo</h2>
            <ul className="beneficios">
              <li><h3>Cuenta sin cuota de manejo</h3><p>Guarda tu dinero sin costos fijos mensuales.</p></li>
              <li><h3>Transferencias inmediatas</h3><p>Envía a otras cuentas del banco y se refleja al instante.</p></li>
              <li><h3>Atención en línea todos los días</h3><p>Resuelve tus dudas desde el celular, cualquier día de la semana.</p></li>
            </ul>
          </div>
        </section>

        <section className="sec sec-soft" id="productos" aria-labelledby="prod-t">
          <div className="sec-in">
            <h2 id="prod-t">Lo que puedes hacer con tu cuenta</h2>
            <Tabs etiqueta="Productos de Banco Digital" tabs={tabs} />
          </div>
        </section>

        <section className="sec sec-paper" id="pasos" aria-labelledby="pasos-t">
          <div className="sec-in sec-dos">
            <div>
              <h2 id="pasos-t">Cómo abrir tu cuenta</h2>
              <ol className="pasos">
                <li><h3>Regístrate con tu cédula</h3><p>Llena el formulario con tus datos; toma pocos minutos.</p></li>
                <li><h3>Recibe tu número de cuenta y usuario</h3><p>Te los entregamos al terminar el registro.</p></li>
                <li><h3>Empieza a usar el banco</h3><p>Ingresa, abre bolsillos, haz transferencias y pide créditos.</p></li>
              </ol>
            </div>
            <Foto zona="pasos" className="foto-lado" />
          </div>
        </section>

        <section className="sec sec-brand" id="seguridad" aria-labelledby="seg-t">
          <div className="sec-in sec-dos sec-dos-inv">
            <Foto zona="seguridad" className="foto-lado" />
            <div>
              <h2 id="seg-t">Tu dinero, bien cuidado</h2>
              <ul className="seguridad">
                <li><h3>Sesiones protegidas</h3><p>Tu sesión es personal y se cierra cuando sales.</p></li>
                <li><h3>Contraseñas protegidas</h3><p>Guardamos tu contraseña cifrada; nadie puede leerla.</p></li>
                <li><h3>Saldos respaldados en la base de datos</h3><p>Cada movimiento queda registrado y tu saldo se calcula a partir de ellos.</p></li>
              </ul>
            </div>
          </div>
        </section>

        <section className="cta" aria-labelledby="cta-t">
          <div className="cta-in">
            <div className="cta-texto">
              <h2 id="cta-t">Abre tu cuenta hoy</h2>
              <p>Solo necesitas tu cédula. Empieza a ahorrar con 12% E.A. desde el primer día.</p>
              <div className="hero-acciones">
                <Link to="/registro" className="btn btn-sun">Registrarse</Link>
                <Link to="/login" className="btn btn-claro">Ingresar</Link>
              </div>
            </div>
            <Foto zona="cta" className="cta-foto" />
          </div>
        </section>
      </main>

      <footer className="pie">
        <div className="pie-in">
          <div className="pie-cols">
            <div>
              <strong className="marca">Banco Digital</strong>
              <p>Tu dinero, simple y seguro, desde cualquier lugar.</p>
            </div>
            <nav aria-label="Productos">
              <h2>Productos</h2>
              <ul>
                <li><a href="#productos">Cuenta y bolsillos</a></li>
                <li><a href="#productos">CDT</a></li>
                <li><a href="#productos">Créditos</a></li>
                <li><a href="#productos">Referidos</a></li>
              </ul>
            </nav>
            <nav aria-label="Ayuda">
              <h2>Ayuda</h2>
              <ul>
                <li><a href="#pasos">Cómo abrir tu cuenta</a></li>
                <li><a href="#seguridad">Seguridad</a></li>
                <li><Link to="/login">Ingresar</Link></li>
                <li><Link to="/registro">Registrarse</Link></li>
              </ul>
            </nav>
            <div>
              <h2>Legal</h2>
              <ul>
                <li>Proyecto académico, sin valor comercial.</li>
                <li>No es una entidad financiera vigilada.</li>
              </ul>
            </div>
          </div>
          <p className="pie-fotos">Fotografías de Unsplash: {creditos.join(', ')}.</p>
          <p className="pie-copy">© Banco Digital. Proyecto académico de Bases de datos</p>
        </div>
      </footer>
    </div>
  );
}
