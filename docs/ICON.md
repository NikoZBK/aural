# App icon

Aural's icon is an EQ response shaped like the letter A, drawn in Aural's instrument cyan over a faint log-frequency and dB grid on a graphite tile. The response is flat at 0 dB with one tall boost: its straight sides are the legs of the A, rounded where they leave 0 dB like a filter's skirt, and the crossbar lies on the +6 dB grid line. It follows the macOS icon grid: an 824 pt rounded tile with a 100 pt transparent margin on a 1024 pt canvas.

- `Resources/AppIcon.png` — the idle icon: the A alone. Finder and the stopped or bypassed app use it.
- `Resources/AppIconActive.png` — shown in the Dock, main window, and About window while EQ is processing: the same A, lit inside. It has no node marker at the apex, which would make the letter read as Å.

The menu bar uses a compact native headphones symbol.

## Regenerating

The artwork is drawn in code, so there are no source files to keep beyond the script.

```sh
swift scripts/draw-icon.swift      # writes both PNGs to Resources/
bash scripts/make-icon.sh          # packages Resources/AppIcon.icns and AppIconActive.icns
```

`make-icon.sh` resizes each PNG with `sips` and packages every macOS icon size with `iconutil`. Pass a name to package one icon, for example `bash scripts/make-icon.sh AppIconActive`.
