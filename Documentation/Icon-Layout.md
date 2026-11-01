# Native macOS icon layout — 2026-10-31

The original artwork is preserved. Native export now uses a transparent canvas,
an inset rounded plate, and optically adjusted small-size variants. At 1024px the
visible plate is 824px with 100px margins; 512/256/128/64/32/16 sizes use the
corresponding legacy macOS production-grid insets. Decomposer retains its existing
Icon Composer continuous-corner shape; the other two use rounded white plates.

The running Dock icon is explicitly supplied by these apps. It therefore needs
the already framed legacy ICNS representation, rather than full-bleed artwork.
This is native export/format conversion, not regenerated artwork.

Grid provenance (primary implementation citing Apple's production templates):
https://chromium.googlesource.com/chromium/src/+/4852d4ffeefa31265675175f00edcf84c5e30ecd/chrome/browser/web_applications/os_integration/mac/icon_utils.mm
Apple icon guidance:
https://developer.apple.com/design/human-interface-guidelines/app-icons/

Native ImageIO/Core Graphics performs the export. Master artwork stays unchanged.
PNG-backed ICNS variants and asset-catalog sizes are updated. App executables and
helpers are not rebuilt for this resource-only update. Installed after confirmed quit; bundle signatures and resource preimages verified, previous bundles retained. App/helper code unchanged.
