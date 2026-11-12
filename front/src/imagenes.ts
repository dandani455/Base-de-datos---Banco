/**
 * Registro interno de fotos. Una foto = una zona. Antes de añadir una, revisa
 * public/img/REGISTRO.md. Los componentes obtienen las imágenes SOLO con imagen(zona).
 */
export type Zona =
  | 'hero'
  | 'tab-bolsillos'
  | 'tab-cdt'
  | 'tab-creditos'
  | 'tab-referidos'
  | 'pasos'
  | 'seguridad'
  | 'cta';

export interface Imagen {
  id: string;
  archivo: string;
  alt: string;
  fotografo: string;
  urlUnsplash: string;
  zona: Zona;
  ancho: number;
  alto: number;
}

export const ZONAS: Zona[] = [
  'hero', 'tab-bolsillos', 'tab-cdt', 'tab-creditos', 'tab-referidos', 'pasos', 'seguridad', 'cta',
];

export const IMAGENES: Imagen[] = [
  {
    id: '_zXn5wWkQig', archivo: 'hero-medellin.jpg', zona: 'hero', ancho: 1600, alto: 1067,
    alt: 'Vista de Medellín con sus barrios en la ladera de las montañas bajo un cielo nublado',
    fotografo: 'Jose Figueroa', urlUnsplash: 'https://unsplash.com/photos/_zXn5wWkQig',
  },
  {
    id: 'Bzl-cftbnTc', archivo: 'tab-bolsillos.jpg', zona: 'tab-bolsillos', ancho: 1100, alto: 733,
    alt: 'Mujer sonriente hablando por celular en una calle de Cartagena, junto a un camión amarillo',
    fotografo: 'Jorge Gardner', urlUnsplash: 'https://unsplash.com/photos/Bzl-cftbnTc',
  },
  {
    id: 'rPNek8KyCXU', archivo: 'tab-cdt.jpg', zona: 'tab-cdt', ancho: 900, alto: 1260,
    alt: 'Mujer joven revisando su celular bajo un arco en una calle peatonal de la ciudad',
    fotografo: 'Kris Tian', urlUnsplash: 'https://unsplash.com/photos/rPNek8KyCXU',
  },
  {
    id: '6l1JgmIIL28', archivo: 'tab-creditos.jpg', zona: 'tab-creditos', ancho: 1100, alto: 733,
    alt: 'Calle de Bogotá cubierta de sombrillas de colores, con gente caminando de día',
    fotografo: 'Reza Madani', urlUnsplash: 'https://unsplash.com/photos/6l1JgmIIL28',
  },
  {
    id: 'UYK_9CFHCBI', archivo: 'tab-referidos.jpg', zona: 'tab-referidos', ancho: 900, alto: 1350,
    alt: 'Grupo de personas caminando juntas por una calle concurrida de Bogotá con los cerros al fondo',
    fotografo: 'Reza Madani', urlUnsplash: 'https://unsplash.com/photos/UYK_9CFHCBI',
  },
  {
    id: 'Qg0ci7cH7e4', archivo: 'pasos-cartagena.jpg', zona: 'pasos', ancho: 900, alto: 1260,
    alt: 'Calle del centro histórico de Cartagena con balcones coloniales y la cúpula de la catedral al fondo',
    fotografo: 'Zane Bolen', urlUnsplash: 'https://unsplash.com/photos/Qg0ci7cH7e4',
  },
  {
    id: 'yfBzdMIbJCY', archivo: 'seguridad-bogota.jpg', zona: 'seguridad', ancho: 900, alto: 1350,
    alt: 'Hombre caminando por una calle de Bogotá junto a edificios altos y los cerros orientales',
    fotografo: 'Jimmy Hu', urlUnsplash: 'https://unsplash.com/photos/yfBzdMIbJCY',
  },
  {
    id: 'izPZjLPrc8s', archivo: 'cta-guatape.jpg', zona: 'cta', ancho: 900, alto: 1350,
    alt: 'Mujer con vestido amarillo caminando por una calle empedrada y colorida de Guatapé',
    fotografo: 'Robbie', urlUnsplash: 'https://unsplash.com/photos/izPZjLPrc8s',
  },
];

/** Devuelve la única foto registrada para la zona; falla con un mensaje claro si falta. */
export function imagen(zona: Zona): Imagen {
  const img = IMAGENES.find((i) => i.zona === zona);
  if (!img) throw new Error(`imagenes.ts: no hay ninguna foto registrada para la zona "${zona}"`);
  return img;
}

export const rutaImagen = (img: Imagen) => `/img/${img.archivo}`;
