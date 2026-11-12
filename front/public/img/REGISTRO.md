# Registro de fotos

**Una foto = una zona.** Antes de añadir una foto, revisa este registro y `src/imagenes.ts`: ninguna foto puede usarse dos veces. Los componentes obtienen las imágenes solo con `imagen(zona)` a través de `<Foto>`.

## Sistema de imágenes

- **Pocas fotos, una sola serie.** Solo hay foto donde una persona aporta calidez y nada más puede hacerlo: la banda de cierre de la página de inicio, Ingresar y Registro. Las tres son de **Reza Madani** en La Candelaria (Bogotá): misma luz de día nublado, mismo color, mismo lugar. Si cambias una, busca otra de la misma serie (o de una sola sesión con la misma luz).
- **Un solo marco.** `<Foto>` pinta siempre `.foto`: proporción fija 4/5 (`vertical`) o 4/3 (`horizontal`), radio de 20px, `object-fit: cover`, recorte explícito con `posicion` (object-position) en `imagenes.ts` y el mismo tratamiento `saturate(.92) contrast(1.02)`. Sin arcos, sin giros, sin máscaras y sin nada encima de la foto (ni tarjetas, ni etiquetas, ni velos).
- Todo lo demás que necesita un visual se dibuja con piezas de interfaz (teléfono, tarjeta, bolsillos, CDT, tabla de cuotas, invitación) dentro del marco de ilustración.

| Archivo | Zona | Fotógrafo | Enlace en Unsplash |
|---|---|---|---|
| cierre-candelaria.jpg | cierre | Reza Madani | https://unsplash.com/photos/UYK_9CFHCBI |
| login-candelaria.jpg | login | Reza Madani | https://unsplash.com/photos/g2VWPFnWp6E |
| registro-sombrillas.jpg | registro | Reza Madani | https://unsplash.com/photos/6l1JgmIIL28 |

## Licencia

Las fotos se publican bajo la [Licencia de Unsplash](https://unsplash.com/license): uso libre, incluido comercial, sin obligación de atribuir. Aun así damos crédito al fotógrafo en la tabla de arriba y en el pie de la página de inicio. Las imágenes están alojadas en el propio proyecto (no se cargan desde Unsplash) para que la demo funcione con mala conexión; se redimensionaron y recomprimieron como JPEG (< 350 kB cada una).
