import { useEffect, useState } from 'react';

export default function ErrorBanner() {
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const on = () => setVisible(true);
    window.addEventListener('conexion-perdida', on);
    return () => window.removeEventListener('conexion-perdida', on);
  }, []);
  if (!visible) return null;
  return (
    <div role="alert" className="banner">
      Error de conexión, estamos trabajando para solucionarlo
      <button onClick={() => setVisible(false)} aria-label="Cerrar">×</button>
    </div>
  );
}
