/**
 * Piezas de interfaz para cada pestaña de productos. Todas con el mismo trazo: una tarjeta
 * blanca con borde de 1px dentro del marco de ilustración. Solo ilustrativas (datos de ejemplo,
 * aria-hidden en quien las usa).
 */

function Anillo({ pct }: { pct: number }) {
  const r = 20;
  const c = 2 * Math.PI * r;
  return (
    <svg className="anillo" viewBox="0 0 48 48" width="48" height="48" style={{ ['--c' as string]: c, ['--off' as string]: c * (1 - pct / 100) }}>
      <circle cx="24" cy="24" r={r} fill="none" className="anillo-pista" strokeWidth="5" />
      <circle className="anillo-valor" cx="24" cy="24" r={r} fill="none" strokeWidth="5" strokeDasharray={c} transform="rotate(-90 24 24)" />
    </svg>
  );
}

/** Fila de celdas cuadradas que se llenan una a una (el "libro contable"). */
function Celdas({ total, llenas }: { total: number; llenas: number }) {
  return (
    <span className="celdas">
      {Array.from({ length: total }, (_, i) => (
        <i key={i} className={i < llenas ? 'llena' : undefined} style={{ ['--i' as string]: i }} />
      ))}
    </span>
  );
}

export function FragBolsillos() {
  return (
    <div className="ui">
      <p className="ui-cabeza"><b>Tus bolsillos</b><span className="ui-dato">12% E.A.</span></p>
      <div className="ui-fila">
        <Anillo pct={68} />
        <span className="ui-txt"><b>Viajes</b><small>$1.360.000 de $2.000.000</small></span>
        <span className="ui-num">68%</span>
      </div>
      <div className="ui-fila">
        <Anillo pct={40} />
        <span className="ui-txt"><b>Emergencias</b><small>$800.000 de $2.000.000</small></span>
        <span className="ui-num">40%</span>
      </div>
      <p className="ui-pie"><span>Rendimiento de hoy</span><b className="ui-pos">+$1.284</b></p>
    </div>
  );
}

export function FragCdt() {
  return (
    <div className="ui">
      <p className="ui-cabeza"><b>CDT a 6 meses</b><span className="ui-dato">Activo</span></p>
      <svg className="ui-linea" viewBox="0 0 352 112">
        {[16, 48, 80].map((y) => <line key={y} x1="0" x2="352" y1={y} y2={y} className="ui-guia" />)}
        <path className="ui-linea-trazo" pathLength={1} d="M0 104 L58 96 L117 86 L176 72 L234 56 L293 36 L346 16" />
        <rect x="340" y="10" width="12" height="12" className="ui-linea-punto" />
      </svg>
      <p className="ui-meses"><span>Mes 1</span><span>Mes 6</span></p>
      <p className="ui-pie"><span>Sin retiro anticipado</span><b>Crece cada día</b></p>
    </div>
  );
}

export function FragCreditos() {
  const filas = [['3', '$412.300', 'Pagada'], ['4', '$398.900', 'Con abono'], ['5', '$398.900', 'Pendiente']];
  return (
    <div className="ui">
      <p className="ui-cabeza"><b>Libre inversión</b><span className="ui-dato">Desembolsado</span></p>
      <table className="ui-tabla">
        <thead><tr><th>Cuota</th><th>Valor</th><th>Estado</th></tr></thead>
        <tbody>
          {filas.map(([n, v, e]) => <tr key={n}><td>{n}</td><td>{v}</td><td>{e}</td></tr>)}
        </tbody>
      </table>
      <p className="ui-pie"><span>Cuotas pagadas</span><Celdas total={12} llenas={3} /></p>
    </div>
  );
}

export function FragReferidos() {
  return (
    <div className="ui">
      <p className="ui-cabeza"><b>Invita a tus amigos</b><span className="ui-dato">3 se unieron</span></p>
      <p className="ui-codigo"><span>bancodigital.co/registro?ref=…</span><b>Copiar</b></p>
      <div className="ui-amigos">
        {['AM', 'JC', 'SR'].map((a) => <span key={a} className="ui-avatar">{a}</span>)}
        <span className="ui-avatar ui-avatar-vacio">+</span>
      </div>
      <p className="ui-pie"><span>Por cada amigo</span><b className="ui-pos">+$50.000</b></p>
    </div>
  );
}
