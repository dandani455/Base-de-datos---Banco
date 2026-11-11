import { useCarga } from '../../api/useApi';
import type { Balance, Dashboard as Datos } from '../../api/types';
import EnvioForm from '../../components/EnvioForm';
import TransaccionList from '../../components/TransaccionList';
import { moneda } from '../../format';

export default function Dashboard() {
  const { data, error, recargar } = useCarga<Datos>('/dashboard');
  const bol = useCarga<Balance>('/bolsillos');
  const enviado = () => { recargar(); bol.recargar(); };
  return (
    <>
      {error && <p role="alert">{error}</p>}
      {data && (
        <>
          <h1>Hola, {data.nombre}</h1>
          <p className="saldo-bloque"><span className="saldo-label">Balance total:</span> <strong className="saldo-monto">{moneda(data.balance_total)}</strong></p>
          <div className="resumen">
            <article aria-label="Resumen CDTs"><h3>CDTs</h3>
              <p>Activos: {data.cdts.activos}</p><p>Generado: {moneda(data.cdts.generado)}</p></article>
            <article aria-label="Resumen créditos"><h3>Créditos</h3>
              <p>Cuota por pagar: {moneda(data.creditos.cuota_por_pagar)}</p>
              <p>Interés corriendo: {moneda(data.creditos.interes_corriendo)}</p></article>
          </div>
          <h2>Últimas transacciones</h2>
          <TransaccionList items={data.transacciones} />
        </>
      )}
      <EnvioForm bolsillos={bol.data?.bolsillos} onEnviado={enviado} />
    </>
  );
}
