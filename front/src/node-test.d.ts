// Tipos mínimos de Node para los tests que leen el sistema de archivos (sin añadir @types/node).
declare module 'node:fs' { export function existsSync(ruta: string): boolean; }
declare module 'node:path' { export function resolve(...partes: string[]): string; }
declare const process: { cwd(): string };
