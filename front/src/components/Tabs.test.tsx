import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import Tabs from './Tabs';

const tabs = [
  { id: 'a', etiqueta: 'Uno', contenido: <p>texto uno</p> },
  { id: 'b', etiqueta: 'Dos', contenido: <p>texto dos</p> },
  { id: 'c', etiqueta: 'Tres', contenido: <p>texto tres</p> },
];

describe('Tabs', () => {
  it('roles, seleccion y panel visible', () => {
    render(<Tabs etiqueta="Prueba" tabs={tabs} />);
    expect(screen.getByRole('tablist', { name: 'Prueba' })).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: 'Uno' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tabpanel')).toHaveTextContent('texto uno');
    expect(screen.getAllByRole('tabpanel', { hidden: true })).toHaveLength(3);
  });
  it('flechas, Fin e Inicio mueven la seleccion y el foco', async () => {
    const u = userEvent.setup();
    render(<Tabs etiqueta="Prueba" tabs={tabs} />);
    screen.getByRole('tab', { name: 'Uno' }).focus();
    await u.keyboard('{ArrowRight}');
    expect(screen.getByRole('tab', { name: 'Dos' })).toHaveFocus();
    expect(screen.getByRole('tabpanel')).toHaveTextContent('texto dos');
    await u.keyboard('{End}');
    expect(screen.getByRole('tab', { name: 'Tres' })).toHaveAttribute('aria-selected', 'true');
    await u.keyboard('{ArrowRight}');
    expect(screen.getByRole('tab', { name: 'Uno' })).toHaveFocus();
    await u.keyboard('{ArrowLeft}{Home}');
    expect(screen.getByRole('tab', { name: 'Uno' })).toHaveAttribute('aria-selected', 'true');
  });
});
