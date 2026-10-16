# BCR2000 / BCF2000 SysEx protocol (working notes)

Source: _BC MIDI Implementation_ (Mark van den Berg), `~/Dropbox/MidiQ/Reference docs/B-Control/BC_MIDI_Implementation.pdf`. Only what the tools in this repo need.

## Frame

```
F0 00 20 32 <dev> <model> <cmd> <data…> F7
```

- `dev`: 0x00–0x0F (device ID 1–16) or `0x7F` = any. The device always answers with its own ID.
- `model`: `0x14` BCF2000, `0x15` BCR2000, `0x7F` = any.

## Commands used here

| cmd                         | dir     | data                                                                      | notes                                                                                                            |
| --------------------------- | ------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `0x01` Request Identity     | host→BC | —                                                                         | reply `0x02`                                                                                                     |
| `0x02` Send Identity        | BC→host | ASCII, e.g. `BCR2000 1.10`                                                |                                                                                                                  |
| `0x20` BCL message          | both    | `idxMSB idxLSB text`                                                      | 14-bit index, first line of a chain must be 0; text ≤ ~512 chars, ASCII 32–127                                   |
| `0x21` BCL reply            | BC→host | `idxMSB idxLSB err`                                                       | one per received `0x20`; length 11 bytes total. Same cmd byte is reused for Preset Name replies (longer message) |
| `0x40` Request Data         | host→BC | `0..31` preset, `0x7E` global+all filled presets, `0x7F` temporary preset | reply is a `0x20` chain ending in `$end`                                                                         |
| `0x41` Request Global Setup | host→BC | —                                                                         | `0x20` chain                                                                                                     |
| `0x42` Request Preset Name  | host→BC | `0..31`, `0x7E`, `0x7F`                                                   |                                                                                                                  |
| `0x22` Select Preset        | host→BC | `0..31`                                                                   | no reply                                                                                                         |

## BCL chain rules

- Chain = `$rev R1` (BCR) / `$rev F1` (BCF) … `$end`, one line per `0x20` message, indices consecutive from 0. An index of 0 restarts a chain.
- Lines starting with `;` are comments: accepted, acknowledged with error 0, never stored. Empty lines are also accepted. **This makes a comment-only chain a safe stress payload.**
- `$store n` is the only persistent write; a `$preset` block without `$store` only touches the temporary preset.

## BCL reply error codes

0 ok · 1 unknown token · 2 data without token · 3 argument missing · 4 wrong model (`$rev`) · 5 wrong revision · 6 missing revision · 8 wrong context (index/chain order) · 11 value out of range · 12 argument too long · 14 invalid number of arguments. See §21.2 of the PDF for the full list.

## Global settings relevant to timing

- `.txinterval {2,5,10,20,50,100}` ms affects element output only; **does not affect SysEx dump timing**.
- No BCL setting slows the device's SysEx _reception_; pacing must come from the host.
