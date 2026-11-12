import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api/client';
import Tabs from '../components/Tabs';
import Contador from '../components/landing/Contador';
import { EscenaHero, TarjetaVirtual, useInclinacion } from '../components/landing/Escena';
import { FragBolsillos, FragCdt, FragCreditos, FragReferidos } from '../components/landing/Fragmentos';
import { prefiereMenosMovimiento, useReveal } from '../hooks/useReveal';
import Foto from '../components/Foto';
import { IMAGENES, type Zona } from '../imagenes';

interface Producto { nombre: string; descripcion?: string }

const FALLBACK: Producto[] = [
  { nombre: 'Crédito de libre inversión', descripcion: 'Dinero para lo que necesites, con cuotas fijas.' },
  { nombre: 'Crédito de vivienda', descripcion: 'Financia la casa de tus sueños a largo plazo.' },
  { nombre: 'Crédito de vehículo', descripcion: 'Estrena carro o moto con tasas competitivas.' },
  { nombre: 'Crédito educativo', descripcion: 'Invierte en tu formación y la de tu familia.' },
];

const MARQUESINA = [
  'Sin cuota de manejo', 'Transferencias inmediatas', '12% E.A. en bolsillos',
  'CDT sin sorpresas', 'Créditos con desembolso inmediato', 'Atención todos los días',
];

/** Envoltorio que se revela al entrar en pantalla (un solo efecto: opacidad + 24px). */
function Revela({ as: Tag = 'div', className = '', children, retraso }: { as?: 'div' | 'li' | 'section'; className?: string; children: ReactNode; retraso?: number }) {
  const { ref } = useReveal<HTMLElement>();
  return (
    <Tag ref={ref as never} className={`reveal ${className}`} style={retraso ? { transitionDelay: `${retraso}ms` } : undefined}>
      {children}
    </Tag>
  );
}

/** Botón que se acerca un poco al puntero (solo ratón y sin movimiento reducido). */
function useMagnetico<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || prefiereMenosMovimiento() || window.matchMedia('(hover: none)').matches) return;
    let raf = 0;
    const mover = (e: PointerEvent) => {
      if (e.pointerType !== 'mouse') return;
      const r = el.getBoundingClientRect();
      const x = (e.clientX - (r.left + r.width / 2)) * 0.25;
      const y = (e.clientY - (r.top + r.height / 2)) * 0.35;
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => { el.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`; });
    };
    const salir = () => { cancelAnimationFrame(raf); el.style.transform = ''; };
    el.addEventListener('pointermove', mover);
    el.addEventListener('pointerleave', salir);
    return () => { el.removeEventListener('pointermove', mover); el.removeEventListener('pointerleave', salir); cancelAnimationFrame(raf); };
  }, []);
  return ref;
}

/** Barra de navegación que se condensa al hacer scroll + barra de progreso de lectura. */
function useScrollNav() {
  const [condensada, setCondensada] = useState(false);
  const progreso = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    let raf = 0;
    const leer = () => {
      raf = 0;
      const y = window.scrollY;
      setCondensada(y > 24);
      const max = document.documentElement.scrollHeight - window.innerHeight;
      if (progreso.current) progreso.current.style.transform = `scaleX(${max > 0 ? Math.min(1, y / max) : 0})`;
    };
    const alScroll = () => { if (!raf) raf = requestAnimationFrame(leer); };
    leer();
    window.addEventListener('scroll', alScroll, { passive: true });
    window.addEventListener('resize', alScroll);
    return () => { window.removeEventListener('scroll', alScroll); window.removeEventListener('resize', alScroll); cancelAnimationFrame(raf); };
  }, []);
  return { condensada, progreso };
}

/** Pasos con línea de progreso: CSS scroll-driven donde existe; si no, cuenta los pasos visibles. */
function Pasos() {
  const [vistos, setVistos] = useState(0);
  const lista = useRef<HTMLOListElement | null>(null);
  useEffect(() => {
    const el = lista.current;
    if (!el) return;
    if (typeof IntersectionObserver === 'undefined') { setVistos(3); return; }
    const items = Array.from(el.querySelectorAll('li'));
    const io = new IntersectionObserver((ents) => {
      for (const e of ents) if (e.isIntersecting) e.target.classList.add('is-on');
      setVistos(items.filter((i) => i.classList.contains('is-on')).length);
    }, { rootMargin: '0px 0px -35% 0px', threshold: 0.5 });
    items.forEach((i) => io.observe(i));
    return () => io.disconnect();
  }, []);
  const pasos = [
    ['Regístrate con tu cédula', 'Llena el formulario con tus datos; toma pocos minutos.'],
    ['Recibe tu número de cuenta y usuario', 'Te los entregamos al terminar el registro.'],
    ['Empieza a usar el banco', 'Ingresa, abre bolsillos, haz transferencias y pide créditos.'],
  ];
  return (
    <div className="pasos-wrap" style={{ ['--vistos' as string]: vistos / pasos.length }}>
    <span className="pasos-pista" aria-hidden="true"><span className="pasos-relleno" /></span>
    <ol className="pasos" ref={lista}>
      {pasos.map(([t, d], i) => (
        <li key={t} className="paso">
          <span className="paso-num" aria-hidden="true">{i + 1}</span>
          <div className="paso-card"><h3>{t}</h3><p>{d}</p></div>
        </li>
      ))}
    </ol>
    </div>
  );
}

function PanelTab({ zona, titulo, fragmento, children }: { zona: Zona; titulo: string; fragmento: ReactNode; children: ReactNode }) {
  return (
    <div className="panel-tab">
      <div className="panel-texto">
        <h3>{titulo}</h3>
        {children}
        <Link to="/registro" className="enlace-flecha">Abrir mi cuenta</Link>
      </div>
      <div className="panel-visual">
        <Foto zona={zona} className={`panel-foto foto-${zona}`} />
        <div className="panel-frag" aria-hidden="true">{fragmento}</div>
      </div>
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
  const { condensada, progreso } = useScrollNav();
  const magHero = useMagnetico<HTMLAnchorElement>();
  const magCta = useMagnetico<HTMLAnchorElement>();
  const tiltCta = useInclinacion<HTMLDivElement>(12);

  const tabs = [
    {
      id: 'bolsillos', etiqueta: 'Cuenta y bolsillos',
      contenido: (
        <PanelTab zona="tab-bolsillos" titulo="Tu cuenta, dividida a tu manera" fragmento={<FragBolsillos />}>
          <p>Cada bolsillo rinde 12% E.A., pagado todos los días. Puedes abrir varios para separar lo que ahorras de lo que gastas.</p>
        </PanelTab>
      ),
    },
    {
      id: 'cdt', etiqueta: 'CDT',
      contenido: (
        <PanelTab zona="tab-cdt" titulo="CDT a tu medida" fragmento={<FragCdt />}>
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
          <div className="panel-visual">
            <Foto zona="tab-creditos" className="panel-foto" />
            <div className="panel-frag" aria-hidden="true"><FragCreditos /></div>
          </div>
        </div>
      ),
    },
    {
      id: 'referidos', etiqueta: 'Referidos',
      contenido: (
        <PanelTab zona="tab-referidos" titulo="Sistema de referidos" fragmento={<FragReferidos />}>
          <p>Invita y gana $50.000 COP por cada amigo que se una a Banco Digital.</p>
        </PanelTab>
      ),
    },
  ];

  const creditos = [...new Set(IMAGENES.map((i) => i.fotografo))];

  return (
    <div className="landing">
      <div className="progreso" ref={progreso} aria-hidden="true" />
      <header className={`nav${condensada ? ' is-condensada' : ''}`}>
        <div className="nav-in">
          <a href="#inicio" className="marca"><span className="marca-logo" aria-hidden="true" />Banco Digital</a>
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
        <section className="hero oscuro" aria-labelledby="hero-t">
          <div className="hero-fondo" aria-hidden="true">
            <Foto zona="hero" className="hero-foto" prioridad decorativa />
            <span className="mancha mancha-1" /><span className="mancha mancha-2" /><span className="mancha mancha-3" />
            <span className="hero-rejilla" />
          </div>
          <div className="hero-in">
            <div className="hero-texto">
              <h1 id="hero-t" className="hero-marca"><span className="pulso" aria-hidden="true" />Banco Digital</h1>
              <p className="hero-titular">
                <span className="linea"><span>Tu dinero,</span></span>
                <span className="linea"><span>siempre</span></span>
                <span className="linea"><span className="grad">contigo.</span></span>
              </p>
              <p className="hero-sub">Abre tu cuenta con tu cédula, ahorra con 12% E.A. pagado cada día y pide créditos con desembolso inmediato.</p>
              <div className="hero-acciones">
                <Link to="/registro" className="btn btn-sun btn-xl" ref={magHero}>Registrarse<span className="btn-flecha" aria-hidden="true">→</span></Link>
                <Link to="/login" className="btn btn-claro btn-xl">Ingresar</Link>
              </div>
              <p className="hero-nota">Sin cuota de manejo · Solo necesitas tu cédula</p>
            </div>
            <EscenaHero />
          </div>
          <a href="#beneficios" className="hero-scroll" aria-label="Bajar a beneficios"><span /></a>
        </section>

        <div className="marquesina" aria-hidden="true">
          <div className="marquesina-pista">
            {[0, 1].map((k) => (
              <ul key={k}>
                {MARQUESINA.map((m) => <li key={m}>{m}<span className="estrella">✦</span></li>)}
              </ul>
            ))}
          </div>
        </div>

        <section className="sec oscuro numeros" id="beneficios" aria-labelledby="ben-t">
          <div className="sec-in">
            <Revela><h2 id="ben-t" className="titulo-xl">Un banco que no te cobra <span className="grad">por tenerlo</span></h2></Revela>
            <div className="stats">
              <Revela className="stat">
                <span className="stat-num"><Contador hasta={12} formato={(n) => `${Math.round(n)}%`} /></span>
                <span className="stat-txt"><b>E.A. en tus bolsillos</b>pagado todos los días</span>
              </Revela>
              <Revela className="stat" retraso={120}>
                <span className="stat-num"><Contador hasta={50000} formato={(n) => '$' + Math.round(n).toLocaleString('es-CO')} /></span>
                <span className="stat-txt"><b>Bono de referido</b>por cada amigo que se une</span>
              </Revela>
              <Revela className="stat" retraso={240}>
                <span className="stat-num"><Contador hasta={360} /></span>
                <span className="stat-txt"><b>Meses de plazo</b>hasta 360 para tu vivienda</span>
              </Revela>
            </div>
            <ul className="beneficios">
              <Revela as="li"><span className="ben-ico" aria-hidden="true">◎</span><h3>Cuenta sin cuota de manejo</h3><p>Guarda tu dinero sin costos fijos mensuales.</p></Revela>
              <Revela as="li" retraso={100}><span className="ben-ico" aria-hidden="true">⇄</span><h3>Transferencias inmediatas</h3><p>Envía a otras cuentas del banco y se refleja al instante.</p></Revela>
              <Revela as="li" retraso={200}><span className="ben-ico" aria-hidden="true">☀</span><h3>Atención en línea todos los días</h3><p>Resuelve tus dudas desde el celular, cualquier día de la semana.</p></Revela>
            </ul>
          </div>
        </section>

        <section className="sec claro productos-sec" id="productos" aria-labelledby="prod-t">
          <div className="sec-in">
            <Revela className="sec-cabeza">
              <h2 id="prod-t" className="titulo-xl">Lo que puedes hacer con tu cuenta</h2>
              <p>Ahorra, invierte, pide prestado e invita a tus amigos. Todo desde la misma app.</p>
            </Revela>
            <Tabs etiqueta="Productos de Banco Digital" tabs={tabs} />
          </div>
        </section>

        <section className="sec papel pasos-sec" id="pasos" aria-labelledby="pasos-t">
          <div className="sec-in sec-dos">
            <div>
              <Revela><h2 id="pasos-t" className="titulo-xl">Cómo abrir tu cuenta</h2>
                <p className="sec-lead">Tres pasos y listo. Sin filas, sin papeles.</p></Revela>
              <Pasos />
            </div>
            <Revela className="pasos-visual">
              <Foto zona="pasos" className="foto-lado" />
              <span className="sello" aria-hidden="true"><b>3</b>pasos</span>
            </Revela>
          </div>
        </section>

        <section className="sec oscuro seguridad-sec" id="seguridad" aria-labelledby="seg-t">
          <div className="seg-fondo" aria-hidden="true"><Foto zona="seguridad" className="seg-foto" decorativa /></div>
          <div className="sec-in sec-dos sec-dos-inv">
            <div className="escudo-wrap" aria-hidden="true">
              <svg className="escudo" viewBox="0 0 200 220">
                <defs>
                  <linearGradient id="escudo-g" x1="0" x2="1" y1="0" y2="1">
                    <stop offset="0" stopColor="#22D3C5" /><stop offset="1" stopColor="#0B4F6C" />
                  </linearGradient>
                </defs>
                <circle className="onda o1" cx="100" cy="110" r="70" />
                <circle className="onda o2" cx="100" cy="110" r="70" />
                <path className="escudo-cuerpo" d="M100 14 L176 42 V104 C176 152 144 188 100 206 C56 188 24 152 24 104 V42 Z" fill="url(#escudo-g)" />
                <path className="escudo-borde" pathLength={1} d="M100 14 L176 42 V104 C176 152 144 188 100 206 C56 188 24 152 24 104 V42 Z" fill="none" stroke="#E6F2F5" strokeWidth="3" />
                <rect x="74" y="104" width="52" height="42" rx="8" fill="#061A24" />
                <path d="M84 104 V90 a16 16 0 0 1 32 0 V104" fill="none" stroke="#061A24" strokeWidth="9" strokeLinecap="round" />
                <circle cx="100" cy="122" r="6" fill="#F4B400" />
                <rect x="97" y="124" width="6" height="12" rx="3" fill="#F4B400" />
              </svg>
            </div>
            <div>
              <Revela><h2 id="seg-t" className="titulo-xl">Tu dinero, <span className="grad">bien cuidado</span></h2></Revela>
              <ul className="seguridad">
                <Revela as="li"><h3>Sesiones protegidas</h3><p>Tu sesión es personal y se cierra cuando sales.</p></Revela>
                <Revela as="li" retraso={100}><h3>Contraseñas protegidas</h3><p>Guardamos tu contraseña cifrada; nadie puede leerla.</p></Revela>
                <Revela as="li" retraso={200}><h3>Saldos respaldados en la base de datos</h3><p>Cada movimiento queda registrado y tu saldo se calcula a partir de ellos.</p></Revela>
              </ul>
            </div>
          </div>
        </section>

        <section className="cta" aria-labelledby="cta-t">
          <div className="cta-in oscuro">
            <span className="mancha mancha-cta" aria-hidden="true" />
            <div className="cta-texto">
              <h2 id="cta-t" className="titulo-gigante">Abre tu cuenta <span className="grad">hoy</span></h2>
              <p>Solo necesitas tu cédula. Empieza a ahorrar con 12% E.A. desde el primer día.</p>
              <div className="hero-acciones">
                <Link to="/registro" className="btn btn-sun btn-xl" ref={magCta}>Registrarse<span className="btn-flecha" aria-hidden="true">→</span></Link>
                <Link to="/login" className="btn btn-claro btn-xl">Ingresar</Link>
              </div>
            </div>
            <div className="cta-visual">
              <Foto zona="cta" className="cta-foto" />
              <div className="cta-tarjeta" aria-hidden="true"><div className="tarjeta-tilt" ref={tiltCta}><TarjetaVirtual /></div></div>
            </div>
          </div>
        </section>
      </main>

      <footer className="pie oscuro">
        <div className="pie-in">
          <div className="pie-cols">
            <div>
              <strong className="marca"><span className="marca-logo" aria-hidden="true" />Banco Digital</strong>
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
          <p className="pie-gigante" aria-hidden="true">Banco Digital</p>
          <p className="pie-fotos">Fotografías de Unsplash: {creditos.join(', ')}.</p>
          <p className="pie-copy">© Banco Digital. Proyecto académico de Bases de datos</p>
        </div>
      </footer>
    </div>
  );
}
