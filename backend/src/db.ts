import { Pool } from 'pg';

/** Única lista de funciones de la BD que el backend puede invocar. */
export const WHITELIST = new Set([
  // auth
  'registrar_usuario', 'verificar_correo', 'obtener_credenciales', 'validar_sesion',
  // cliente
  'nombre_destinatario', 'hacer_transferencia',
  'crear_bolsillo', 'mover_a_bolsillo', 'retirar_de_bolsillo', 'mover_entre_bolsillos',
  'crear_cdt', 'simular_cdt', 'simular_credito', 'solicitar_credito', 'pagar_cuota', 'abonar_credito',
  'activar_descuento_automatico',
  'vista_dashboard', 'vista_historial', 'vista_cdts', 'vista_creditos', 'vista_perfil',
  // HUECOS: pendientes de crear en la BD (ver README)
  'vista_balance', 'renombrar_bolsillo', 'listar_cdt_definiciones', 'productos_publicos',
  'admin_get_reloj', 'admin_get_tasas',
  // admin
  'admin_listar_usuarios', 'admin_detalle_usuario', 'admin_bloquear', 'admin_desbloquear', 'admin_borrar_usuario',
  'admin_ajustar_balance', 'admin_set_reloj', 'admin_set_tasa_cdt', 'admin_set_tasa_credito', 'admin_set_tasa_mora',
  'admin_esquema', 'admin_tabla',
]);

export type Row = Record<string, any>;
export interface Db {
  call(fn: string, args?: unknown[]): Promise<Row[]>;
  /** Varias llamadas en una sola transacción SQL (solo funciones de la whitelist). */
  tx(calls: [string, unknown[]][]): Promise<void>;
}

function sqlDe(fn: string, n: number) {
  if (!WHITELIST.has(fn)) throw new Error(`Función no permitida: ${fn}`);
  return `SELECT * FROM ${fn}(${Array.from({ length: n }, (_, i) => `$${i + 1}`).join(',')})`;
}

export function crearDb(connectionString = process.env.DATABASE_URL): Db {
  const pool = new Pool({ connectionString, max: 10, connectionTimeoutMillis: 2000, idleTimeoutMillis: 30000, query_timeout: 10000 });
  // Un cliente inactivo que falla (BD apagada) NO debe tumbar el proceso.
  pool.on('error', (e) => console.error('[pg pool]', e.message));
  return {
    async call(fn, args = []) {
      return (await pool.query(sqlDe(fn, args.length), args as any[])).rows;
    },
    async tx(calls) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        for (const [fn, args] of calls) await client.query(sqlDe(fn, args.length), args as any[]);
        await client.query('COMMIT');
      } catch (e) {
        await client.query('ROLLBACK').catch(() => {});
        throw e;
      } finally {
        client.release();
      }
    },
  };
}
