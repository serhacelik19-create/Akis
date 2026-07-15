# Akış

> **A local-first memory companion for the thoughts you mean to return to.**

Akış turns a thought like _“Yarın sabah Ece’yi ara, sunumu da gözden geçir”_
into calm, reviewable next steps — without turning life into another noisy task
list.

Built **for Turkish speakers**, Akış understands the way people naturally
express time, promises, and unfinished thoughts in Turkish. It is not an
English-first assistant translated into Turkish; its current interpretation
rules are written around everyday Turkish language patterns.

## The idea

Most things we forget are not tasks. They are promises, half-formed ideas,
people we meant to reply to, and decisions we wanted to revisit.

Akış gives those thoughts a place to land. It captures them as an open loop,
asks for confirmation before acting, and brings them back at the right moment.

## What Akış can do

- Turn free-form Turkish text into a task, reminder, note, or list.
- Understand natural time expressions:
  `2 dakika sonra`, `yarın sabah`, `17.45`, `beşe çeyrek kala`.
- Separate multiple instructions into individual, reviewable cards.
- Recognise promise-like wording and keep it as an **open loop**.
- Resurface open loops later instead of letting them disappear into a backlog.
- Schedule and restore local notifications through the operating system.
- Search, complete, reopen, defer, or delete saved cards.
- Capture voice on macOS using Apple on-device speech recognition.

## Designed around privacy

Akış is local-first by default.

- Cards live in a local SQLite database.
- Voice is transcribed with the device's on-device speech capability on macOS.
- Temporary audio files are removed after transcription.
- No external AI API, cloud account, or downloaded language model is required
  for the core experience.

## How it works

```text
Thought, typed or spoken
          │
          ▼
 Turkish intent + time interpreter
          │
          ▼
     Review before saving
          │
          ▼
 Local SQLite ─────► Local notification
          │
          └────────► Open-loop review later
```

Every interpretation stays visible to the user before it is saved. If time is
missing or ambiguous, Akış asks a direct follow-up instead of quietly guessing.

## Tech

| Area | Choice |
| --- | --- |
| App | Flutter / Dart |
| Local storage | SQLite |
| Notifications | `flutter_local_notifications` |
| Voice on macOS | AVFoundation + Apple Speech |
| Time zones | `timezone` + device time zone |

## Run locally

```bash
flutter pub get
flutter run -d macos
```

Quality checks:

```bash
flutter analyze
flutter test
flutter build macos --debug
```

## Platform status

| Platform | Status |
| --- | --- |
| macOS | Core flow, local notifications, and on-device speech input are implemented. |
| iOS / Android / Windows | Flutter targets exist; native voice and notification behaviour still need platform-specific implementation and device validation. |

## Project structure

```text
lib/
├── core/       Turkish intent and time interpretation
├── data/       SQLite persistence
├── models/     Card and open-loop domain models
└── services/   Lifecycle, notification, audio, and speech services
```

## Notes

- Local databases, temporary WAV files, and build output are excluded from Git.
- The project intentionally avoids bundling large local models, keeping the
  repository lightweight and the core flow easy to run.
