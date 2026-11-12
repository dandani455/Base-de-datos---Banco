// Arranca el mock y Vite juntos; al salir mata ambos.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const raiz = fileURLToPath(new URL('..', import.meta.url));
const hijos = [
  spawn(process.execPath, ['mock/server.mjs'], { cwd: raiz, stdio: 'inherit' }),
  spawn('npx', ['vite'], { cwd: raiz, stdio: 'inherit', env: { ...process.env, VITE_DEMO: 'true' } }),
];
const salir = () => { for (const h of hijos) h.kill(); };
process.on('SIGINT', salir); process.on('SIGTERM', salir);
for (const h of hijos) h.on('exit', salir);
