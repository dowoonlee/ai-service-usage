# App icon

`AppIcon.png` is the original, transparent image generated with the built-in
ImageGen tool. The orange pixel cat and cyan usage chart reflect the app's pets
and dark usage dashboard. Keep the transparent margin when replacing the source.

`bash scripts/build-app-icon.sh` builds `dist/AppIcon.icns` with macOS `sips` and
`iconutil` (16–1024 px, including Retina representations). `scripts/package.sh`
automatically builds it into the app's outer `Contents/Resources` directory and
sets `CFBundleIconFile`. No image-generation service is needed during builds.

Generation prompt:

> Use case: logo-brand. Create one production macOS app icon for AI Usage, a compact dark AI subscription usage dashboard with playful collectible pixel pets walking on usage charts. Square 1024x1024 PNG. A polished dark charcoal rounded-square macOS tile with generous transparent outside margins (tile occupies about 82 percent of canvas width), straight-on, no perspective. Central bold symbol: a charming original small warm orange pixel-art cat with squared ears, two dark eyes and a curled tail, standing on a thick turquoise ascending three-step usage chart. Cat should be big and instantly legible; symbol occupies most of tile interior. Pixel-art silhouette with restrained bevel lighting, crisp geometric edges, premium and friendly developer desktop utility aesthetic. Charcoal #252730 tile, warm orange #FF9F32 pet, turquoise #21BCD4 chart. Extremely simple composition, strong silhouette at 32px, no text, no letters, no numbers, no logos, no tiny details, no extra objects, no frame or surrounding mockup. Actual transparent background outside the rounded tile, subtle shadow only.
