# LUT library manifest

Catalog snapshot retrieved 2026-10-09. Original asset bytes are unmodified.
Each entry records the source URL and Git blob SHA-1; downloads must match it.
Six Film-Luts files and nine samples from the three added libraries are bundled.
The remaining catalog files are downloaded on demand and cached locally.

| Collection | Entries | Input / output | Basis |
| --- | ---: | --- | --- |
| [Film-Luts](https://github.com/YahiaAngelo/Film-Luts) | 6 | sRGB / sRGB | Assumed, not declared in CUBE |
| [hald-clut](https://github.com/cedeber/hald-clut) | 350 | sRGB / sRGB | Assumed; mixed upstream sources |
| [PoLUT](https://github.com/TomPoczos/PoLUT) | 196 | Adobe RGB (1998) / Adobe RGB (1998) | Default files and generator explicitly declare this |
| [film-lab](https://github.com/thedevmark/film-lab) | 1 | sRGB / sRGB | Gold 200 baking instructions and attribution explicitly declare this |

PoLUT is GPL-3.0; see PoLUT-LICENSE. Hald-clut is marked GPL-3.0 but aggregates
several sources; see hald-clut-LICENSE and review original asset provenance
before redistributing a product. Film-Luts' MIT notice and original disclaimer
are preserved in ../FilmLuts. film-lab Gold 200 is CC BY-SA 4.0, derived from
Andrea Volpato's spektrafilm data. Its complete attribution and authoritative
SPEKTRAFILM_LICENSE.txt are included here. The LUT was not modified by this project.

Unknown color spaces are not inferred from filenames. `certainty: assumed`
is deliberately visible in the GUI. A manifest entry can specify srgb,
adobeRGB1998, linearSRGB, displayP3, or rec709 (camera OETF, not gamma 2.4).
An unknown encoding fails decoding rather than silently defaulting to sRGB.
