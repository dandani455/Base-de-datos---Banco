import { useEffect, useState } from 'react';

export default function ErrorBanner() {
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const on = () => setVisible(true);
    const off = () => setVisible(false);
    window.addEventListener('conexion-perdida', on);
    window.addEventListener('conexion-restablecida', off);
    return () => {
      window.removeEventListener('conexion-perdida', on);
      window.removeEventListener('conexion-restablecida', off);
    };
  }, []);
  if (!visible) return null;
  return (
    <div role="alert" className="banner">
      Error de conexión, estamos trabajando para solucionarlo
      <button onClick={() => setVisible(false)} aria-label="Cerrar">×</button>
    </div>
  );
}
