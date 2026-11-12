import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client';
import Tabs from '../components/Tabs';
import Contador from '../components/landing/Contador';
import { EscenaHero } from '../components/landing/Escena';
import { FragBolsillos, FragCdt, FragCreditos, FragReferidos } from '../components/landing/Fragmentos';
import { prefiereMenosMovimiento, useReveal } from '../hooks/useReveal';
import Foto from '../components/Foto';
import { IMAGENES } from '../imagenes';

interface Producto { nombre: string; descripcion?: string }

const FALLBACK: Producto[] = [
  { nombre: 'Crédito de libre inversión', descripcion: 'Dinero para lo que necesites, con cuotas fijas.' },
  { nombre: 'Crédito de vivienda', descripcion: 'Financia la casa de tus sueños a largo plazo.' },
  { nombre: 'Crédito de vehículo', descripcion: 'Estrena carro o moto con tasas competitivas.' },
  { nombre: 'Crédito educativo', descripcion: 'Invierte en tu formación y la de tu familia.' },
];

/** Envoltorio que se revela al entrar en pantalla (un solo efecto, sutil: opacidad + 8px). */
function Revela({ className = '', children }: { className?: string; children: ReactNode }) {
  const { ref } = useReveal<HTMLDivElement>();
  return <div ref={ref} className={`reveal ${className}`.trim()}>{children}</div>;
}

/** Marca: un cuadrado de 2×2 celdas con una celda amarilla. */
function Marca({ como = 'a' }: { como?: 'a' | 'strong' }) {
  const contenido = <><span className="marca-logo" aria-hidden="true"><i /><i /><i /><i /></span>Banco Digital</>;
  return como === 'a' ? <a href="#inicio" className="marca">{contenido}</a> : <strong className="marca">{contenido}</strong>;
}

/** La barra de navegación se condensa (fondo sólido y menos alto) al hacer scroll. */
function useNavCondensada() {
  const [condensada, setCondensada] = useState(false);
  useEffect(() => {
    let raf = 0;
    const leer = () => { raf = 0; setCondensada(window.scrollY > 24); };
    const alScroll = () => { if (!raf) raf = requestAnimationFrame(leer); };
    leer();
    window.addEventListener('scroll', alScroll, { passive: true });
    return () => { window.removeEventListener('scroll', alScroll); cancelAnimationFrame(raf); };
  }, []);
  return condensada;
}

const PASOS = [
  ['Regístrate con tu cédula', 'Llenas un formulario corto con tus datos.'],
  ['Recibe tu usuario', 'Te damos tu número de cuenta al terminar.'],
  ['Empieza a usarlo', 'Abre bolsillos, transfiere y pide créditos.'],
];

/** Progreso (0–1) de la lista de pasos según el scroll; 1 de entrada sin movimiento o sin medidas. */
function usePasosProgreso() {
  const ref = useRef<HTMLDivElement | null>(null);
  const [p, setP] = useState(1);
  useEffect(() => {
    const el = ref.current;
    if (!el || prefiereMenosMovimiento()) return;
    let raf = 0;
    const leer = () => {
      raf = 0;
      const r = el.getBoundingClientRect();
      const vh = window.innerHeight;
      if (!r.height || !vh) { setP(1); return; }
      // 0 cuando la lista asoma por abajo; 1 cuando su base sube hasta el 60% de la pantalla.
      const inicio = vh * 0.9;
      const fin = vh * 0.45;
      setP(Math.min(1, Math.max(0, (inicio - r.top) / (inicio - fin + r.height * 0.5))));
    };
    const alScroll = () => { if (!raf) raf = requestAnimationFrame(leer); };
    leer();
    window.addEventListener('scroll', alScroll, { passive: true });
    window.addEventListener('resize', alScroll);
    return () => { window.removeEventListener('scroll', alScroll); window.removeEventListener('resize', alScroll); cancelAnimationFrame(raf); };
  }, []);
  return { ref, p };
}

function Pasos() {
  const { ref, p } = usePasosProgreso();
  return (
    <div className="pasos-wrap" ref={ref} style={{ ['--p' as string]: p }}>
    <span className="pasos-pista" aria-hidden="true"><span className="pasos-relleno" /></span>
    <ol className="pasos rejilla">
      {PASOS.map(([t, d], i) => (
        <li key={t} className={`paso${p >= i / PASOS.length + 0.02 || p === 1 ? ' is-on' : ''}`}>
          <span className="paso-marca" aria-hidden="true" />
          <span className="paso-num" aria-hidden="true">{String(i + 1).padStart(2, '0')}</span>
          <h3>{t}</h3>
          <p>{d}</p>
        </li>
      ))}
    </ol>
    </div>
  );
}

function PanelTab({ titulo, texto, fragmento, children }: { titulo: string; texto: ReactNode; fragmento: ReactNode; children?: ReactNode }) {
  return (
    <div className="panel-tab">
      <div className="panel-texto">
        <h3>{titulo}</h3>
        <p>{texto}</p>
        {children}
        <Link to="/registro" className="btn btn-tinta">Abrir mi cuenta</Link>
      </div>
      <div className="marco-ilustracion panel-frag" aria-hidden="true">{fragmento}</div>
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
  const condensada = useNavCondensada();

  const tabs = [
    {
      id: 'bolsillos', etiqueta: 'Cuenta y bolsillos',
      contenido: <PanelTab titulo="Separa tu plata en bolsillos" texto="Cada bolsillo rinde 12% E.A., pagado todos los días." fragmento={<FragBolsillos />} />,
    },
    {
      id: 'cdt', etiqueta: 'CDT',
      contenido: <PanelTab titulo="Un CDT a tu medida" texto="Eliges monto y plazo; la rentabilidad se acumula cada día." fragmento={<FragCdt />} />,
    },
    {
      id: 'creditos', etiqueta: 'Créditos',
      contenido: (
        <PanelTab titulo="Plata cuando la necesitas" texto="Desembolso inmediato. Si abonas a capital, la cuota baja." fragmento={<FragCreditos />}>
          <ul className="productos">
            {productos.map((p) => (
              <li key={p.nombre} data-testid="producto" title={p.descripcion}>{p.nombre}</li>
            ))}
          </ul>
        </PanelTab>
      ),
    },
    {
      id: 'referidos', etiqueta: 'Referidos',
      contenido: <PanelTab titulo="Invita a tus amigos" texto="Invita y gana $50.000 COP por cada amigo que se una a Banco Digital." fragmento={<FragReferidos />} />,
    },
  ];

  const creditos = [...new Set(IMAGENES.map((i) => i.fotografo))];

  return (
    <div className="landing">
      <header className={`nav${condensada ? ' is-condensada' : ''}`}>
        <div className="contenedor nav-in">
          <Marca />
          <nav aria-label="Secciones" className="nav-sec">
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
        <section className="hero noche" aria-labelledby="hero-t">
          <div className="contenedor rejilla cuadricula hero-in">
            <div className="hero-texto">
              <h1 id="hero-t" className="sr-only">Banco Digital</h1>
              <p className="hero-titular">Tu plata, tranquila.</p>
              <p className="hero-sub">Abre tu cuenta con tu cédula y ahorra con 12% E.A. pagado cada día. Sin cuota de manejo.</p>
              <div className="acciones">
                <Link to="/registro" className="btn btn-sun btn-l">Registrarse</Link>
                <Link to="/login" className="btn btn-linea btn-l">Ingresar</Link>
              </div>
            </div>
            <EscenaHero />
          </div>
        </section>

        <section className="banda papel" id="productos" aria-labelledby="prod-t">
          <div className="contenedor">
            <div className="rejilla cabeza">
              <h2 id="prod-t" className="titulo">Lo que puedes hacer</h2>
              <p className="cabeza-linea">Ahorra, invierte, pide prestado e invita. Todo desde la misma app.</p>
            </div>
            <Tabs etiqueta="Productos de Banco Digital" tabs={tabs} />
          </div>
        </section>

        <section className="banda sol banda-cifras" aria-labelledby="cifras-t">
          <Revela className="contenedor rejilla">
            <div className="cifra-grande">
              <h2 id="cifras-t" className="sr-only">Cifras de Banco Digital</h2>
              <p className="cifra-num"><Contador hasta={12} formato={(n) => `${Math.round(n)}%`} /><span className="cifra-unidad">E.A.</span></p>
              <p className="cifra-txt">En tus bolsillos, pagado todos los días.</p>
            </div>
            <dl className="cifras-pequenas">
              <div>
                <dt>Por cada amigo que invites</dt>
                <dd><Contador hasta={50000} formato={(n) => '$' + Math.round(n).toLocaleString('es-CO')} /></dd>
              </div>
              <div>
                <dt>Plazo para tu vivienda</dt>
                <dd>hasta <Contador hasta={360} /> meses</dd>
              </div>
            </dl>
          </Revela>
        </section>

        <section className="banda niebla" id="pasos" aria-labelledby="pasos-t">
          <div className="contenedor">
            <div className="rejilla cabeza">
              <h2 id="pasos-t" className="titulo">Cómo abrir tu cuenta</h2>
            </div>
            <Pasos />
          </div>
        </section>

        <section className="banda noche seguridad-sec" id="seguridad" aria-labelledby="seg-t">
          <div className="contenedor rejilla cuadricula">
            <Revela className="escudo-wrap">
              <svg className="escudo" viewBox="0 0 384 384" aria-hidden="true">
                {[[64, 32], [288, 64], [32, 192], [288, 256], [128, 320], [320, 160], [0, 96]].map(([x, y], i) => (
                  <rect key={i} className="celda-escudo" x={x} y={y} width="32" height="32" style={{ ['--i' as string]: i }} />
                ))}
                <path className="escudo-cuerpo" d="M192 48 L304 88 V180 C304 248 258 298 192 324 C126 298 80 248 80 180 V88 Z" />
                <path className="escudo-borde" pathLength={1} d="M192 48 L304 88 V180 C304 248 258 298 192 324 C126 298 80 248 80 180 V88 Z" />
                <path className="candado-arco" d="M164 184 V160 a28 28 0 0 1 56 0 V184" />
                <rect className="candado-cuerpo" x="148" y="180" width="88" height="68" rx="8" />
                <rect className="candado-llave" x="186" y="202" width="12" height="24" />
              </svg>
            </Revela>
            <div className="seg-texto">
              <h2 id="seg-t" className="titulo">Cuidamos cada peso.</h2>
              <ul className="seguridad">
                <li><h3>Sesiones protegidas</h3><p>Tu sesión es personal y se cierra cuando sales.</p></li>
                <li><h3>Contraseñas cifradas</h3><p>Nadie puede leer tu contraseña, ni siquiera nosotros.</p></li>
                <li><h3>Cada movimiento, registrado</h3><p>Tu saldo se calcula a partir de tus movimientos.</p></li>
              </ul>
            </div>
          </div>
        </section>

        <section className="banda papel cierre" aria-labelledby="cta-t">
          <div className="contenedor rejilla">
            <Revela className="cierre-foto"><Foto zona="cierre" forma="vertical" /></Revela>
            <div className="cierre-texto">
              <h2 id="cta-t" className="titulo">Abre tu cuenta hoy.</h2>
              <p>Solo necesitas tu cédula. Tu plata empieza a rendir desde el primer día.</p>
              <div className="acciones">
                <Link to="/registro" className="btn btn-sun btn-l">Registrarse</Link>
                <Link to="/login" className="btn btn-linea-tinta btn-l">Ingresar</Link>
              </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="pie noche">
        <div className="contenedor">
          <div className="rejilla pie-cols">
            <div className="pie-marca">
              <Marca como="strong" />
              <p>Tu plata, simple y segura.</p>
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
          <p className="pie-gigante" aria-hidden="true">Banco Digital</p>
          <div className="pie-base">
            <p>© Banco Digital. Proyecto académico de Bases de datos</p>
            <p>Fotografías: {creditos.join(', ')} en Unsplash.</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
