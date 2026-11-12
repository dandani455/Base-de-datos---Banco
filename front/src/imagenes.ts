/**
 * Registro interno de fotos. Una foto = una zona. Antes de añadir una, revisa
 * public/img/REGISTRO.md. Los componentes obtienen las imágenes SOLO con imagen(zona)
 * (a través de <Foto>), que las pinta siempre con el mismo marco.
 *
 * Las tres fotos son de una misma serie (Reza Madani, La Candelaria, Bogotá): misma luz,
 * mismo color y mismo lugar. Si cambias una, busca otra de la misma serie.
 */
export type Zona = 'cierre' | 'login' | 'registro';

export interface Imagen {
  id: string;
  archivo: string;
  alt: string;
  fotografo: string;
  urlUnsplash: string;
  zona: Zona;
  ancho: number;
  alto: number;
  /** object-position explícito para el recorte dentro del marco. */
  posicion: string;
}

export const ZONAS: Zona[] = ['cierre', 'login', 'registro'];

export const IMAGENES: Imagen[] = [
  {
    id: 'UYK_9CFHCBI', archivo: 'cierre-candelaria.jpg', zona: 'cierre', ancho: 1000, alto: 1500, posicion: '50% 70%',
    alt: 'Gente caminando por una calle colorida de La Candelaria, en Bogotá, con los cerros al fondo',
    fotografo: 'Reza Madani', urlUnsplash: 'https://unsplash.com/photos/UYK_9CFHCBI',
  },
  {
    id: 'g2VWPFnWp6E', archivo: 'login-candelaria.jpg', zona: 'login', ancho: 1000, alto: 1500, posicion: '50% 72%',
    alt: 'Calle concurrida del centro de Bogotá con sombrillas de mercado y las montañas detrás',
    fotografo: 'Reza Madani', urlUnsplash: 'https://unsplash.com/photos/g2VWPFnWp6E',
  },
  {
    id: '6l1JgmIIL28', archivo: 'registro-sombrillas.jpg', zona: 'registro', ancho: 1400, alto: 933, posicion: '72% 50%',
    alt: 'Calle de Bogotá cubierta de sombrillas de colores, con gente caminando de día',
    fotografo: 'Reza Madani', urlUnsplash: 'https://unsplash.com/photos/6l1JgmIIL28',
  },
];

/** Devuelve la única foto registrada para la zona; falla con un mensaje claro si falta. */
export function imagen(zona: Zona): Imagen {
  const img = IMAGENES.find((i) => i.zona === zona);
  if (!img) throw new Error(`imagenes.ts: no hay ninguna foto registrada para la zona "${zona}"`);
  return img;
}

export const rutaImagen = (img: Imagen) => `/img/${img.archivo}`;
