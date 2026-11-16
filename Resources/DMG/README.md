# DMG background

`background.png` is the static Finder background used by `script/package_dmg.sh`.
It is 1600 × 1000 pixels at 144 DPI, giving an 800 × 500 point canvas with
Retina detail. Keep the native app and Applications icons out of the artwork;
Finder draws them at (200, 250) and (600, 250).

The background uses warm ivory, orange waveform ribbons, and piano-roll marks.
The title, arrow, and instructions are part of the image. To change the layout,
update the packaging coordinates and check the mounted DMG in Finder.

Created with the built-in image generation tool, then sized and tagged with
`sips` for Finder. Packaging uses this checked-in asset and never calls an image
service.

## Generation prompt

```text
Use case: stylized-concept
Asset type: final Finder background graphic for the Unableton macOS drag-to-Applications disk image.
Generate exactly one landscape image, 1600 by 1000 pixels, aspect ratio 8:5. This will display at 800 by 500 logical points. Design a tasteful music-themed installer background that feels like a beautifully printed modern electronic music record sleeve. Warm ivory/off-white central canvas with fine paper texture; sculptural burnt-orange and amber audio wave ribbons, restrained charcoal piano-roll marks and rhythm lines mostly around the top-right and bottom-left edges. Match an app whose icon is a dark charcoal rounded square with pale equalizer bars and one orange center bar. No logos, no external brand names, no fake screenshots.
Layout requirements, coordinates described at the 800 by 500 logical point display: At (60,55) top left set the title 'Unableton' in bold clean charcoal modern sans-serif, about 32 points, with the smaller subtitle 'Music, made editable.' below it at y=100. Leave very generous clear light negative space around two icon positions centered at (200,250) and (600,250), including below each for native Finder labels to y=330. These two areas must remain plain warm ivory. Do NOT draw icons, circles, buttons, boxes, placeholders, app symbols, folder symbols or labels for these positions: Finder draws the actual interactive icons. Between them centered at (400,250), draw one thin clear charcoal horizontal right-pointing arrow, from x=350 to450. At bottom center around y=425, set exact instruction text 'Drag Unableton to Applications' in a legible charcoal sans-serif about 17 points. Below it around y=453, smaller softer text 'Then open Unableton from Applications.' approximately 11 points. Artwork can gently flow behind the edges but never obscure text, native icon spaces, or instructions.
High design quality, crisp typography, balanced composition, subtle music-studio character, no extra slogans, no ornamental treble clefs, no heavy borders, no watermarks. Background must be opaque.
```
