# Klappkordeon 🪗

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
