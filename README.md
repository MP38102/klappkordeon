# Klappkordeon 🪗

*[English below](#english)*

Ein Akkordeon für das MacBook: Der Bildschirmdeckel ist der Balg. Du hältst Tasten gedrückt und bewegst den Deckel auf und zu. Ohne Bewegung gibt es keine Luft und damit keinen Ton. Je schneller du bewegst, desto lauter und heller klingt es.

## Voraussetzungen

- MacBook mit Deckelwinkel-Sensor (MacBook Pro ab 2019, MacBook Air/Pro mit Apple Silicon)
- macOS 14 oder neuer
- Xcode Command Line Tools (`xcode-select --install`)

Ohne Sensor (z. B. am Mac mini) funktioniert Zwei-Finger-Scrollen als Balg.

## Bauen

```bash
./build.sh
open Klappkordeon.app
```

## Spielen

Die App ist auf Deutsch und Englisch, umschalten oben rechts (DE/EN).


| Eingabe | Funktion |
|---|---|
| Deckel bewegen | Balg: öffnen = Zug, schließen = Druck |
| Mittlere Tastenreihe (A S D F …) | Weiße Tasten, ab C4 |
| Obere Reihe (W E T Z U …) | Schwarze Tasten |
| Zahlen 1–0 | Bass + Akkord (C, G, F, Am, Dm, Em, D, E, A, B) |
| ← / → | Oktave verschieben |

**Register:** Musette (drei leicht verstimmte Zungen), Klarinette, Bandoneon, Master.

**Spielart Wechseltönig:** Wie bei einer Steirischen klingt dieselbe Taste beim Öffnen (Zug) anders als beim Schließen (Druck).

## Wie es funktioniert

- Der Deckelwinkel kommt über IOKit HID vom Sensor `VendorID 0x05AC / ProductID 0x8104` (Feature-Report 1, Winkel in Grad).
- Aus der Winkeländerung der letzten ~180 ms wird die Balggeschwindigkeit berechnet und daraus der Luftdruck.
- Der Klang wird live mit `AVAudioSourceNode` synthetisiert: bandbegrenzte Säge- und Pulswellen pro Zunge, ein Tiefpass, der mit dem Druck aufgeht, und etwas Hall.

---

## English

An accordion for your MacBook: the lid is the bellows. Hold keys and move the lid open and closed. No movement means no air, so no sound. The faster you move, the louder and brighter it gets.

### Requirements

- MacBook with a lid angle sensor (MacBook Pro 2019 and later, Apple silicon MacBook Air/Pro)
- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)

Without a sensor (e.g. on a Mac mini), two-finger scrolling works as the bellows.

### Build

```bash
./build.sh
open Klappkordeon.app
```

### Play

The app is in German and English, switch with DE/EN in the top right.

| Input | Function |
|---|---|
| Move the lid | Bellows: open = pull, close = push |
| Home row (A S D F …) | White keys, starting at C4 |
| Top row (W E T Y U …) | Black keys |
| Number keys 1–0 | Bass + chord (C, G, F, Am, Dm, Em, D, E, A, B♭) |
| ← / → | Shift octave |

**Registers:** Musette (three slightly detuned reeds), Clarinet, Bandoneon, Master.

**Push-pull mode:** Like a diatonic button accordion, the same key plays a different note when opening (pull) than when closing (push).

### How it works

- The lid angle is read through IOKit HID from the sensor `VendorID 0x05AC / ProductID 0x8104` (feature report 1, angle in degrees).
- Bellows speed is derived from the angle change over the last ~180 ms and turned into air pressure.
- The sound is synthesized live with `AVAudioSourceNode`: band-limited saw and pulse waves per reed, a low-pass filter that opens with pressure, and a little reverb.
