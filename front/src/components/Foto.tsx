import { imagen, rutaImagen, type Zona } from '../imagenes';

export type Forma = 'vertical' | 'horizontal';

/**
 * Única forma de mostrar una foto: el marco `.foto` (proporción fija 4/5 o 4/3, radio 20px,
 * mismo tratamiento de color en todas). Nada se pone encima de la foto.
 */
export default function Foto({ zona, forma = 'vertical', className = '', prioridad = false, decorativa = false }: {
  zona: Zona; forma?: Forma; className?: string; prioridad?: boolean; decorativa?: boolean;
}) {
  const img = imagen(zona);
  return (
    <div className={`foto foto-${forma} ${className}`.trim()}>
      <img
        src={rutaImagen(img)}
        alt={decorativa ? '' : img.alt}
        width={img.ancho}
        height={img.alto}
        style={{ objectPosition: img.posicion }}
        {...(prioridad ? { fetchPriority: 'high' as const } : { loading: 'lazy' as const })}
        decoding="async"
      />
    </div>
  );
}
