# Aural 2.0.1

- Channel delay no longer dulls the delayed channel. Delays now land on the nearest sample, within 0.012 ms of the value you enter at 44.1 kHz.
- Sharp (high-Q) low and high shelves follow their intended shape more closely, most of all at 88.2 kHz and above. Presets that use them may sound slightly different near the shelf.
- An empty audio buffer from macOS can no longer stop EQ on outputs that use the App mixer.
