# App icon

Aural's icon is an EQ response on a graphite tile: a low shelf, a flat midrange, a presence dip, and an air bell, drawn in Aural's instrument cyan over a faint log-frequency and dB grid. It follows the macOS icon grid: an 824 pt rounded tile with a 100 pt transparent margin on a 1024 pt canvas.

- `Resources/AppIcon.png` — the idle icon: the curve alone. Finder and the stopped or bypassed app use it.
- `Resources/AppIconActive.png` — shown in the Dock, main window, and About window while EQ is processing: the same curve, lit underneath, with one node per band.

The menu bar uses a compact native headphones symbol.

## Regenerating

The artwork is drawn in code, so there are no source files to keep beyond the script.

```sh
swift scripts/draw-icon.swift      # writes both PNGs to Resources/
bash scripts/make-icon.sh          # packages Resources/AppIcon.icns and AppIconActive.icns
```

`make-icon.sh` resizes each PNG with `sips` and packages every macOS icon size with `iconutil`. Pass a name to package one icon, for example `bash scripts/make-icon.sh AppIconActive`.
