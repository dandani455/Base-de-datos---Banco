/**
 * Modo demostración: solo existe con `npm run dev:mock` (que fija VITE_DEMO=true).
 * En el build de producción el valor es `false` y todo lo que cuelga de aquí se elimina del bundle.
 */
export const DEMO = import.meta.env.VITE_DEMO === 'true';
