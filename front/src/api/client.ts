export class ConexionError extends Error {
  constructor() {
    super('Error de conexión, estamos trabajando para solucionarlo');
    this.name = 'ConexionError';
  }
}

export class NegocioError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NegocioError';
  }
}

function conexionPerdida(): never {
  window.dispatchEvent(new Event('conexion-perdida'));
  throw new ConexionError();
}

/** Único punto de fetch de la app. El JWT viaja en cookie httpOnly. */
export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`/api${path}`, {
      ...init,
      credentials: 'include',
      headers: { 'Content-Type': 'application/json', ...init.headers },
    });
  } catch {
    return conexionPerdida();
  }
  if (res.status === 503) return conexionPerdida();
  window.dispatchEvent(new Event('conexion-restablecida'));
  const body = await res.json().catch(() => ({}));
  if (res.status === 400) throw new NegocioError(body.error ?? body.message ?? 'Solicitud inválida');
  if (!res.ok) throw new Error(body.error ?? `Error ${res.status}`);
  return body as T;
}
