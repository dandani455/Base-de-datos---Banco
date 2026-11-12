import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { IMAGENES, ZONAS, imagen } from './imagenes';

const dir = resolve(process.cwd(), 'public/img') + '/';

describe('registro de imagenes', () => {
  it('cada zona la usa exactamente una foto', () => {
    for (const z of ZONAS) expect(IMAGENES.filter((i) => i.zona === z), z).toHaveLength(1);
    expect(IMAGENES).toHaveLength(ZONAS.length);
  });
  it('no hay archivos ni urls repetidos', () => {
    expect(new Set(IMAGENES.map((i) => i.archivo)).size).toBe(IMAGENES.length);
    expect(new Set(IMAGENES.map((i) => i.urlUnsplash)).size).toBe(IMAGENES.length);
    expect(new Set(IMAGENES.map((i) => i.id)).size).toBe(IMAGENES.length);
  });
  it('cada archivo existe en public/img', () => {
    for (const i of IMAGENES) expect(existsSync(dir + i.archivo), i.archivo).toBe(true);
  });
  it('cada foto tiene alt, fotografo y medidas', () => {
    for (const i of IMAGENES) {
      expect(i.alt.trim().length, i.archivo).toBeGreaterThan(10);
      expect(i.fotografo.trim()).not.toBe('');
      expect(i.ancho).toBeGreaterThan(0);
      expect(i.alto).toBeGreaterThan(0);
    }
  });
  it('imagen(zona) devuelve la foto o falla con mensaje claro', () => {
    expect(imagen('hero').zona).toBe('hero');
    // @ts-expect-error zona inexistente a proposito
    expect(() => imagen('nada')).toThrow(/zona "nada"/);
  });
});
