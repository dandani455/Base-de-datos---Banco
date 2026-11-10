import { FormEvent, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { api } from '../api/client';

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
    <main>
      <h1>Ingresar</h1>
      <form onSubmit={enviar}>
        <label>Usuario<input value={username} onChange={(e) => setUsername(e.target.value)} required /></label>
        <label>Contraseña<input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {error && <p role="alert">{error}</p>}
        <button type="submit">Ingresar</button>
      </form>
      <p>¿No tienes cuenta? <Link to="/registro">Registrarse</Link></p>
    </main>
  );
}
