# Design sources

- `AppIcon.svg` — the app icon on the 1024 grid, full square (iOS applies the
  squircle). Four groups map to Icon Composer layers: background, iMac, iPad,
  window. Render the asset with:

  ```
  qlmanage -t -s 1024 -o . design/AppIcon.svg   # then flatten alpha before adding to the catalog
  ```

  The three-direction exploration and the final board live on the design
  canvas linked from `docs/BRIEF.md`.

- The Mac app's icon comes from the same file. `Scripts/make-app.sh` renders
  it with Quick Look (`qlmanage -t -s 1024`), makes the render the one layer
  of a generated Icon Composer document, and compiles that with Xcode's
  `actool` into `Assets.car` (macOS 26 and later mask and light it natively)
  plus a pre-masked `AppIcon.icns` for macOS 14–15. A plain `.icns` made with
  `sips`/`iconutil` shows up on macOS 27 as a shrunken icon inside a grey
  tile. The result is cached in `.build/icon`. A layered
  `Packaging/AppIcon.icon` made in Icon Composer from the SVG's four groups
  replaces the generated one as soon as it exists.

- `Packaging/DuoAppIcon.icon` — the Duo Mac icon, a layered Icon Composer
  document (macOS 26/27's format). Two layers: `Assets/screen.svg` is the Mac
  screen the Duo folds around, filled with the blue-teal gradient the app uses
  for streamed video; `Assets/deck.svg` is the lower half, the dark surface you
  type and touch. `icon.json` stacks deck then screen (bottom to top) over a
  near-black `automatic-gradient` background. Layers are unmasked squares on
  the 1024 grid — macOS masks, lights and refracts them itself, so the artwork
  carries no baked corners, specular or shadow.

  The VisionTec "V" sits centred on the screen as a watermark: Montserrat Black
  (the brand's wordmark font), outlined, cap height 210 on the grid, filled with
  a translucent glass gradient lit at its top-left so the screen shows through.
  VisionTec's wordmark spec is in `VisionTec 品牌资源/VisionTec 文字 Logo
  设计规范.md` (in the VisionLab repo): Montserrat 900, uppercase, 0.18em
  tracking. Do not redraw the letter — re-outline it from the font.

  `Scripts/build-duodesk-mac.sh` compiles it with `actool` into `Assets.car`
  plus `DuoAppIcon.icns` and declares both `CFBundleIconName` and
  `CFBundleIconFile`. Icon Composer's own CLI renders any appearance or size
  without building the app:

  ```sh
  ICT='/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'
  "$ICT" Packaging/DuoAppIcon.icon --export-image --output-file /tmp/icon.png \
      --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 27
  ```

  `--rendition` takes `Default`, `Dark`, `ClearLight`, `ClearDark`,
  `TintedLight`, `TintedDark` or `Mono`; `--design-generation 27` renders in the
  current macOS 27 style (`26` shows how macOS 26 drew it).
- `DMGBackground.svg` — the window of Sill.dmg, the Mac download: 660 x 400
  points of white, an arrow from where Sill.app sits (170, 180) to
  Applications (490, 180) in the app icon's greys, and "To install Sill, drag
  it to Applications." under them. `Scripts/make-dmg.sh` renders it with Quick
  Look at 1x and 2x into one TIFF and puts the icons on it with a `.DS_Store`;
  moving either icon means changing the SVG's arrow and the script's `--item`
  lines together (`Tests/checks/dmg-layout` holds the same numbers). Keep
  every edge white: the window is sized for macOS 27's title bar, so under
  macOS 14's and 15's shorter one it shows 4 points below the picture.
- The menu bar glyph is drawn in code from the same geometry
  (`Sources/SillMenuBar/StatusGlyph.swift`): the iMac outline with the tilted
  iPad, as a template image. `SillMenuBar -SillRenderPreviews <dir>` writes
  `glyphs.png` with every state on light and dark bars.
- `screenshots/`: the App Store's iPad screenshots that the README shows, at
  half size (1032 × 1376, JPEG). Open-source app lists link these files, so
  keep their names.
