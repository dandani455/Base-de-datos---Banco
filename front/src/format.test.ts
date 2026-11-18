import { describe, expect, it } from 'vitest';
import { tasaEA } from './format';

describe('tasaEA', () => {
  it('formatea un porcentaje numérico como E.A.', () => {
    expect(tasaEA(12)).toBe('12% E.A.');
    expect(tasaEA(13.5)).toBe('13,5% E.A.');
  });
  it('acepta el número como texto', () => {
    expect(tasaEA('9.25')).toBe('9,25% E.A.');
  });
  it('deja tal cual un texto que ya trae formato', () => {
    expect(tasaEA('1.8% mensual')).toBe('1.8% mensual');
  });
});
