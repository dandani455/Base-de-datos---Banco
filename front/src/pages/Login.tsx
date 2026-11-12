import { FormEvent, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { api } from '../api/client';
import AuthLayout from '../components/AuthLayout';

export default function Login() {
  const nav = useNavigate();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');

  async function enviar(e: FormEvent) {
    e.preventDefault();
    setError('');
    try {
      await api('/auth/login', { method: 'POST', body: JSON.stringify({ username, password }) });
      nav('/app');
    } catch (err) {
      // El mensaje (incluido el de cuenta restringida) viene del servidor y se muestra tal cual.
      setError((err as Error).name === 'ConexionError' ? '' : (err as Error).message || 'Credenciales inválidas');
    }
  }

  return (
    <AuthLayout
      zona="login"
      promesa={<>Qué bueno <span className="grad">verte de nuevo.</span></>}
      detalle="Revisa tu saldo, mueve tu dinero y mira crecer tus bolsillos, desde cualquier lugar."
      puntos={['Transferencias inmediatas', '12% E.A. en tus bolsillos', 'Tu sesión se cierra cuando sales']}
    >
    <main className="publico auth">
      <p className="auth-saludo">Bienvenido a Banco Digital</p>
      <h1>Ingresar</h1>
      <form onSubmit={enviar} className="panel form">
        <label>Usuario<input value={username} onChange={(e) => setUsername(e.target.value)} required /></label>
        <label>Contraseña<input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {error && <p role="alert">{error}</p>}
        <button type="submit">Ingresar</button>
      </form>
      <p className="aparte">¿No tienes cuenta? <Link to="/registro">Registrarse</Link></p>
    </main>
    </AuthLayout>
  );
}
