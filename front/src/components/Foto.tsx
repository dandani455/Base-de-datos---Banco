import { imagen, rutaImagen, type Zona } from '../imagenes';

/** Foto de una zona, siempre desde el registro. El hero se carga con prioridad; el resto en diferido. */
export default function Foto({ zona, className, prioridad = false, decorativa = false }: { zona: Zona; className?: string; prioridad?: boolean; decorativa?: boolean }) {
  const img = imagen(zona);
  return (
    <img
      className={className}
      src={rutaImagen(img)}
      alt={decorativa ? '' : img.alt}
      width={img.ancho}
      height={img.alto}
      {...(prioridad ? { fetchPriority: 'high' as const } : { loading: 'lazy' as const })}
      decoding="async"
    />
  );
}
