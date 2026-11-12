import { act, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import Contador from '../components/landing/Contador';
import { useReveal } from './useReveal';

function Caja() {
  const { ref, visible } = useReveal<HTMLDivElement>();
  return <div ref={ref} data-testid="caja" className="reveal">{visible ? 'si' : 'no'}</div>;
}

afterEach(() => vi.unstubAllGlobals());

describe('useReveal', () => {
  it('sin IntersectionObserver (jsdom) marca el elemento visible de inmediato', () => {
    expect(typeof IntersectionObserver).toBe('undefined');
    render(<Caja />);
    expect(screen.getByTestId('caja')).toHaveClass('is-visible');
    expect(screen.getByTestId('caja')).toHaveTextContent('si');
  });

  it('con IntersectionObserver espera a que entre en pantalla y se desconecta', () => {
    let disparar: (v: boolean) => void = () => {};
    const disconnect = vi.fn();
    class IO {
      constructor(cb: (e: { isIntersecting: boolean; target: Element }[]) => void) {
        disparar = (v) => cb([{ isIntersecting: v, target: document.querySelector('[data-testid=caja]')! }]);
      }
      observe() {}
      disconnect = disconnect;
    }
    vi.stubGlobal('IntersectionObserver', IO);
    render(<Caja />);
    const caja = screen.getByTestId('caja');
    expect(caja).not.toHaveClass('is-visible');
    act(() => disparar(false));
    expect(caja).not.toHaveClass('is-visible');
    act(() => disparar(true));
    expect(caja).toHaveClass('is-visible');
    expect(caja).toHaveTextContent('si');
    expect(disconnect).toHaveBeenCalled();
  });
});

describe('Contador', () => {
  it('sin IntersectionObserver muestra el valor final y no truena', () => {
    render(<Contador hasta={50000} formato={(n) => '$' + Math.round(n).toLocaleString('es-CO')} />);
    expect(screen.getAllByText('$50.000')).toHaveLength(2); // visible (aria-hidden) + texto accesible
  });
});
