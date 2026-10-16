# SideWaveKit

The engine for SideWave2, a smaller rebuild of SideWave around one explicit session state
machine. SideWave is the full app. SideWave2 covers the core loop (dictation, live preview, Refine,
paste) and has fewer features.

| Folder | Contents |
|---|---|
| `Session/` | `SessionState` and `SessionTransition`, a pure state machine; `SessionController` performs its effects. `GestureClassifier` tells a tap from push-to-talk. |
| `Audio/` | CoreAudio capture with a fresh engine for each session. |
| `Recognition/` | NVIDIA Nemotron streaming recognition through FluidAudio, and the gates that drop text with no speech behind it. |
| `Refine/` | Apple Intelligence and Gemma behind one `Refiner` protocol, with the prompts and output checks. |
| `Output/` | The paste cascade. It's a near-copy of SideWave's `TypingService`, so check both when fixing paste. |

Each subsystem sits behind a protocol in `Protocols.swift`. Tests live in `Tests/SideWaveKitTests`
and run with the `SideWave` scheme.
