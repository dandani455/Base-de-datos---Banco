import { useCarga } from '../../api/useApi';
import type { Perfil as Datos } from '../../api/types';

export default function Perfil() {
  const { data, error } = useCarga<Datos>('/perfil');
  return (
    <>
      <h1>Perfil</h1>
      {error && <p role="alert">{error}</p>}
      {data && (
        <dl className="datos panel">
          <dt>Usuario</dt><dd>{data.username}</dd>
          <dt>Número de cuenta</dt><dd>{data.numero_cuenta}</dd>
          <dt>Código de referido</dt><dd>{data.codigo_referido}</dd>
        </dl>
      )}
    </>
  );
}
