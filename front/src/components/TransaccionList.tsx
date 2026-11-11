import type { Transaccion } from '../api/types';
import { fechaHora, moneda } from '../format';

export default function TransaccionList({ items }: { items: Transaccion[] }) {
  if (items.length === 0) return <p className="vacio">Sin transacciones</p>;
  return (
    <ul className="transacciones">
      {items.map((t) => {
        const envio = t.tipo === 'envio';
        return (
          <li key={t.id} data-testid="transaccion" className={envio ? 'envio' : 'recibo'}
              style={{ color: envio ? '#b00020' : '#1b7f3b' }}>
            <strong className="tx-monto">{envio ? '-' : '+'}{moneda(t.monto)}</strong>
            <span className="tx-nombre">{t.contraparte}{t.nota && <em> {t.nota}</em>}</span>
            <small className="tx-fecha">{fechaHora(t.fecha)}</small>
          </li>
        );
      })}
    </ul>
  );
}
