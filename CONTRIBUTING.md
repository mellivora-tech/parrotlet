# Contributing

Thanks for considering a contribution.

## Product boundary

Parrotlet is a macOS menu-bar, context-aware English tutor. Contributions should make that experience more stable, focused, or useful.

The project is intentionally not expanding into:

- a general-purpose ChatGPT client;
- a course platform;
- a cloud-sync service;
- a full SRS system;
- a cross-platform app at this stage.

## Preferred contributions

- macOS compatibility fixes.
- Provider compatibility and offline contract tests.
- Focused UI polish for the chat and lookup flows.
- Prompt-quality improvements for practice and tutoring.
- Persistence reliability and data-recovery improvements.
- Security and privacy hardening.
- Documentation accuracy.

## Before submitting

Run:

```bash
make test
make app
make smoke-compile
```

Ensure:

- no microphone or speech-recognition permission is reintroduced without an explicit design decision;
- no third-party native runtime or downloadable model is reintroduced without a pinned digest and threat-model review;
- README behavior claims remain accurate;
- new UI strings have Chinese and English variants where they use `L10n`;
- tests cover important state transitions and failure paths.
