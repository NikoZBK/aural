# Aural 1.4.0

- Adds Mid/Side filters, 6 dB/octave shelves, a tilt control, and a left/right channel swap.
- Adds optional loudness compensation, which keeps bass and treble full as you turn the volume down.
- Allows up to 64 filters, up from 32.
- Peak protection now catches peaks between samples and eases the level down just before them. It adds about 1.2 ms of delay.
- Each ten-band slider now sets the exact level at its frequency; saved presets convert and keep their sound. Filters also keep their shape at every sample rate, so treble filters at 44.1 and 48 kHz sound slightly different than before.
- Adds level matching for Bypass and A/B, and an On/Off switch for peak protection.
- Gives Aural a new solid look and an icon drawn as an EQ curve shaped like an A.
- Fixes EQ stopping when an app plays invalid audio, bass filters dropping out while you drag, a click when turning peak protection off, and menu buttons taking your Mac's accent color.

Presets that use Mid/Side filters or 6 dB/octave shelves need Aural 1.4. This release includes the in-app updates from 1.3; if you're on 1.2.1 or earlier, install it manually once.
