import { FormEvent, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { api } from '../api/client';

const REGLAS = [
  { texto: 'Mínimo 8 caracteres', ok: (p: string) => p.length >= 8 },
  { texto: 'Una mayúscula', ok: (p: string) => /[A-Z]/.test(p) },
  { texto: 'Un número', ok: (p: string) => /\d/.test(p) },
];

const CAMPOS = [
  ['nombres', 'Nombres', 'text'], ['apellidos', 'Apellidos', 'text'], ['cedula', 'Cédula', 'text'],
  ['correo', 'Correo', 'email'], ['telefono', 'Teléfono', 'tel'], ['fecha_nacimiento', 'Fecha de nacimiento', 'date'],
] as const;

export default function Registro() {
  const [params] = useSearchParams();
  const [ref] = useState(params.get('ref') ?? undefined);
  const [form, setForm] = useState<Record<string, string>>({});
  const [password, setPassword] = useState('');
  const [politica, setPolitica] = useState(false);
  const [error, setError] = useState('');
  const [username, setUsername] = useState('');

  const passOk = REGLAS.every((r) => r.ok(password));

  async function enviar(e: FormEvent) {
    e.preventDefault();
    setError('');
    if (!passOk || !politica) { setError('Revisa la contraseña y acepta la política de datos'); return; }
    try {
      const r = await api<{ username: string }>('/auth/registro', {
        method: 'POST',
        body: JSON.stringify({ ...form, password, acepta_politica: politica, codigo_referido: ref }),
      });
      setUsername(r.username);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  if (username) {
    return (
      <main className="publico auth">
        <h1>¡Registro exitoso!</h1>
        <p>Tu usuario es <strong>{username}</strong>. Guárdalo, solo se muestra una vez.</p>
        <Link to="/login" className="btn btn-sun">Ingresar</Link>
      </main>
    );
  }

  return (
    <main className="publico auth">
      <Link to="/" className="marca">Banco Digital</Link>
      <h1>Crea tu cuenta</h1>
      <form onSubmit={enviar} className="panel form">
        {CAMPOS.map(([k, label, type]) => (
          <label key={k}>{label}
            <input type={type} required value={form[k] ?? ''} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
          </label>
        ))}
        <label>Contraseña
          <input type="password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        <ul className="reglas">
          {REGLAS.map((r) => <li key={r.texto} data-ok={String(r.ok(password))}>{r.texto}</li>)}
        </ul>
        <label className="check">
          <input type="checkbox" checked={politica} onChange={(e) => setPolitica(e.target.checked)} />
          Acepto la política de datos
        </label>
        {error && <p role="alert">{error}</p>}
        <button type="submit" className="btn-sun">Registrarse</button>
      </form>
    </main>
  );
}
