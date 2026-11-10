import type { Transaccion } from '../api/types';
import { fechaHora, moneda } from '../format';

export default function TransaccionList({ items }: { items: Transaccion[] }) {
  if (items.length === 0) return <p>Sin transacciones</p>;
  return (
    <ul className="transacciones">
      {items.map((t) => {
        const envio = t.tipo === 'envio';
        return (
          <li key={t.id} data-testid="transaccion" className={envio ? 'envio' : 'recibo'}
              style={{ color: envio ? '#b00020' : '#1b7f3b' }}>
            <strong>{envio ? '-' : '+'}{moneda(t.monto)}</strong> {t.contraparte} <small>{fechaHora(t.fecha)}</small>
            {t.nota && <em> {t.nota}</em>}
          </li>
        );
      })}
    </ul>
  );
}
