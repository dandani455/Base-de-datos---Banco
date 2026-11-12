# Servidor mock (solo desarrollo)

Permite ver el front sin backend. Node 22, sin dependencias, datos en memoria (se reinician al apagarlo).

- `npm run mock`: levanta el mock en el puerto 3000.
- `npm run dev:mock`: levanta el mock y Vite juntos (Vite hace proxy de `/api` a `127.0.0.1:3000`).
  Con este comando el menú de la landing muestra la pestaña **Demo** (`/demo`): entra al panel de cliente, al de admin o prueba la cuenta restringida sin escribir credenciales. La pestaña y la ruta solo existen con `VITE_DEMO=true` (lo fija `dev:mock`); en el build de producción no se incluyen.

## Usuarios (clave `Banco2026`)

- `jperez483`: cliente con cuenta `4001002003`, 2 bolsillos, 2 CDTs, 2 créditos y 20 transacciones.
- `admin1`: administrador.
- `bloqueado1`: cuenta restringida (el login devuelve el mensaje de bloqueo).

Cuentas destino para probar envíos: `4003004005` (Camila Rodríguez Peña), `4007008009`, `4008009001`.

## Simular caída de la base de datos

```
curl -X POST localhost:3000/__mock/caida   # alterna: todas las rutas /api responden 503 {"error":"sin_conexion"}
curl localhost:3000/__mock/estado
```
