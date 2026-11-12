/** Fragmentos de interfaz para cada pestaña de productos. Solo ilustrativos (aria-hidden en quien los usa). */

function Anillo({ pct, color }: { pct: number; color: string }) {
  const r = 22;
  const c = 2 * Math.PI * r;
  return (
    <svg className="anillo" viewBox="0 0 56 56" width="56" height="56" style={{ ['--c' as string]: c, ['--off' as string]: c * (1 - pct / 100) }}>
      <circle cx="28" cy="28" r={r} fill="none" stroke="currentColor" strokeOpacity=".14" strokeWidth="6" />
      <circle className="anillo-valor" cx="28" cy="28" r={r} fill="none" stroke={color} strokeWidth="6" strokeLinecap="round"
        strokeDasharray={c} transform="rotate(-90 28 28)" />
      <text x="28" y="32.5" textAnchor="middle" fontSize="13" fontWeight="700" fill="currentColor">{pct}%</text>
    </svg>
  );
}

export function FragBolsillos() {
  return (
    <div className="frag frag-bolsillos">
      <div className="mini-card">
        <Anillo pct={68} color="#22D3C5" />
        <span><small>Bolsillo</small><b>Viajes</b><em>$1.360.000 de $2.000.000</em></span>
      </div>
      <div className="mini-card">
        <Anillo pct={40} color="#F4B400" />
        <span><small>Bolsillo</small><b>Emergencias</b><em>$800.000 de $2.000.000</em></span>
      </div>
      <span className="frag-pill">Rinde 12% E.A. · cada día</span>
    </div>
  );
}

export function FragCdt() {
  return (
    <div className="frag frag-cdt">
      <div className="mini-card mini-col">
        <span className="mini-fila"><b>CDT a 6 meses</b><span className="frag-tag">Activo</span></span>
        <svg className="frag-linea" viewBox="0 0 220 70" preserveAspectRatio="none">
          <path className="frag-linea-area" d="M0 66 C 50 62, 90 52, 130 38 S 200 10, 220 6 L220 70 L0 70 Z" />
          <path className="frag-linea-trazo" pathLength={1} d="M0 66 C 50 62, 90 52, 130 38 S 200 10, 220 6" />
        </svg>
        <span className="mini-fila"><small>Vence en 6 meses</small><small>Sin retiro anticipado</small></span>
      </div>
    </div>
  );
}

export function FragCreditos() {
  return (
    <div className="frag frag-creditos">
      <div className="mini-card mini-col">
        <span className="mini-fila"><b>Crédito de libre inversión</b><span className="frag-tag ok">Desembolsado</span></span>
        <span className="frag-barras">
          {[100, 100, 100, 80, 80, 62, 62, 44].map((h, i) => <i key={i} style={{ height: `${h * 0.5}px`, animationDelay: `${i * 60}ms` }} />)}
        </span>
        <span className="mini-fila"><small>Abonas a capital</small><small>la cuota baja</small></span>
      </div>
    </div>
  );
}

export function FragReferidos() {
  return (
    <div className="frag frag-referidos">
      <div className="mini-card">
        <span className="avatares"><i>AM</i><i>JC</i><i>SR</i></span>
        <span><small>Tus amigos se unieron</small><b className="frag-monto">+$50.000</b><em>por cada uno</em></span>
      </div>
    </div>
  );
}
