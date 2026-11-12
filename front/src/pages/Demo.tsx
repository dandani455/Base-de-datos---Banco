import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { api } from '../api/client';

/** Cuentas del mock (front/mock/server.mjs). Solo se usan en modo demostración. */
const CUENTAS = [
  {
    id: 'cliente',
    titulo: 'Panel de cliente',
    detalle: 'Saldo, bolsillos, créditos, CDTs y envíos, con la cuenta de Juan Pérez.',
    username: 'jperez483',
    destino: '/app',
  },
  {
    id: 'admin',
    titulo: 'Panel de administración',
    detalle: 'Usuarios, operaciones, reloj del banco, tasas y control.',
    username: 'admin1',
    destino: '/admin',
  },
  {
    id: 'bloqueado',
    titulo: 'Cuenta restringida',
    detalle: 'El mensaje que recibe un usuario bloqueado al intentar ingresar.',
    username: 'bloqueado1',
    destino: null,
  },
] as const;

type Cuenta = (typeof CUENTAS)[number];

export default function Demo() {
  const nav = useNavigate();
  const [cargando, setCargando] = useState<string | null>(null);
  const [aviso, setAviso] = useState('');

  async function entrar(c: Cuenta) {
    if (cargando) return;
    setCargando(c.id);
    setAviso('');
    try {
      await api('/auth/login', { method: 'POST', body: JSON.stringify({ username: c.username, password: 'Banco2026' }) });
      if (c.destino) nav(c.destino);
    } catch (err) {
      setAviso((err as Error).name === 'ConexionError'
        ? 'El mock no responde. Arráncalo con npm run dev:mock.'
        : (err as Error).message);
    } finally {
      setCargando(null);
    }
  }

  return (
    <div className="demo">
      <div className="demo-in">
        <Link to="/" className="demo-marca">
          <span className="demo-logo" aria-hidden="true"><i /><i /><i /><i /></span>Banco Digital
        </Link>
        <h1>Entra al panel</h1>
        <p className="demo-sub">
          Modo demostración con datos de prueba, sin base de datos. Aquí no hay permisos reales todavía:
          el login de verdad sigue en <Link to="/login">Ingresar</Link>.
        </p>

        <ul className="demo-lista">
          {CUENTAS.map((c, i) => (
            <li key={c.id}>
              <div>
                <h2>{c.titulo}</h2>
                <p>{c.detalle}</p>
                <code>{c.username}</code>
              </div>
              <button
                type="button"
                className={i === 0 ? 'demo-btn demo-btn-sun' : 'demo-btn'}
                disabled={cargando !== null}
                onClick={() => entrar(c)}
              >
                {cargando === c.id ? 'Entrando…' : c.destino ? 'Entrar' : 'Probar'}
              </button>
            </li>
          ))}
        </ul>

        {aviso && <p role="alert" className="demo-aviso">{aviso}</p>}
      </div>
    </div>
  );
}
