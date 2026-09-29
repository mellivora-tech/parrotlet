# Parrotlet

**Parrotlet** is an experimental macOS menu-bar English tutor for Chinese-speaking developers and knowledge workers.

It keeps a lightweight, context-aware conversation one click away in the menu bar: continue a lesson, ask about words and phrases, get corrections, and switch between immersive practice and bilingual tutoring.

> Status: **experimental**. The app is local-first and uses your own LLM API key. Persisted data carries a schema version and migrates forward automatically, but this is still pre-1.0 software.

## What it is for

You are reading an English document, writing an issue or email, or practicing a sentence. Instead of opening a general-purpose chat workspace and re-explaining what you want, you:

1. open the menu-bar chat window;
2. continue the current English-learning conversation;
3. ask about a word, phrase, sentence, or idea you want to express;
4. receive a tutor-style reply with a concise correction;
5. select text inside the conversation for a context-aware explanation.

The product is deliberately **not** a dictionary, course platform, SRS app, cloud service, or general ChatGPT replacement.

## Core features

- Menu-bar resident chat window with a session history sidebar.
- Context-aware conversation: recent turns plus summarized earlier history for long sessions; sessions auto-titled by the LLM.
- Two tutor modes:
  - **Practice**: English-only immersion with at most one concise correction per turn.
  - **Tutor**: bilingual explanations, structured teaching, and direct corrections.
- Selection lookup inside chat, using the surrounding conversation as context.
- System macOS text-to-speech pronunciation.
- Word-bookmark window with search, pronunciation, copy, deletion, and JSON export.
- Chinese and English UI (follows system or manual override).
- API keys stored in the macOS Keychain — never written to disk.
- Automatic updates via Sparkle (EdDSA-signed release feed) for released builds.
- Local JSON storage with schema versioning and forward migration.
- BYO OpenAI-compatible API key.

Removed by design:

- writing-polish mode (folded into the Tutor mode's intent recognition);
- microphone input and speech recognition;
- downloadable Piper voice packages;
- native sherpa-onnx / ONNX Runtime dependencies;
- daily review and SRS-style learning tasks.

## Requirements

- macOS 15.0 or later.
- Apple Silicon (`arm64`).
- Xcode 26.6+ recommended (the app target builds through Swift Package Manager; CLT-only toolchains shipped a broken SPM in some 26.x releases).
- An OpenAI-compatible provider API key, such as DeepSeek, GLM, or Kimi.
- Optional local keyless provider: Ollama on `127.0.0.1`.

The app currently builds as an Apple Silicon binary. Intel and universal2 builds are not provided.

## Build and test

The app compiles via SwiftPM (`Package.swift`); the Makefile bundles the `.app`, embeds Sparkle, signs, and builds the custom (non-XCTest) test runner.

```bash
make test          # offline unit tests
make app           # build, bundle and sign Parrotlet.app
make swift6-typecheck
make smoke-compile # compile the real-network smoke tool without sending a request
```

Signing: if your keychain contains the `Mellivora Local Dev` certificate it is used (stable identity, required for Sparkle update validation); otherwise the build falls back to ad-hoc signing, which is fine for development. Override with `make app CODESIGN_IDENTITY=-`.

Run the real-network smoke manually:

```bash
make llm-smoke
make llm-smoke ARGS=chat
make llm-smoke ARGS=tone               # 20-case tone eval: real requests, scans Chinese output for measured AI tells
make llm-smoke ARGS="tone 5"           # single case
make llm-smoke ARGS="tone 5 baseline"  # same case without the tone rule (A/B)
```

The smoke tool reads your real config file and sends a request to the active provider. Do not run it unless you intend to spend API quota.

Releases (maintainers only): `tools/release.sh <semver>` builds, signs (EdDSA, key in the maintainer's Keychain), uploads to the public [parrotlet-releases](https://github.com/mellivora-tech/parrotlet-releases) repo, and updates the appcast feed.

## LLM providers

Configure providers in the app settings or in:

```text
~/Library/Application Support/Parrotlet/config.json
```

Supported current protocol:

- `openAICompatible`

Presets included for:

- DeepSeek;
- GLM;
- Kimi.

Custom OpenAI-compatible endpoints are also supported.

Base URL rules:

- remote providers must use HTTPS;
- plaintext HTTP is only accepted for loopback addresses such as `127.0.0.1` and `localhost`;
- the base URL should include the version prefix, for example `https://api.example.com/v1`;
- user info, query strings, and fragments are rejected.

Ollama example:

```json
{
  "id": "ollama",
  "kind": "openAICompatible",
  "name": "Ollama",
  "baseURL": "http://127.0.0.1:11434/v1",
  "model": "qwen2.5:7b",
  "apiKey": null
}
```

## API key and data

API keys live in the **macOS Keychain** (one generic-password entry per provider id). `config.json` only holds non-secret settings; keys migrated from older versions are moved to the Keychain automatically on first launch and scrubbed from the file.

Current active files under:

```text
~/Library/Application Support/Parrotlet/
├── config.json         # provider settings (no secrets) and app preferences
├── chat-sessions.json  # conversations and session summaries
├── words.json          # saved lookup explanations
├── app.jsonl           # local run log
└── voices/             # legacy Piper directories; no longer created by the app
```

`words.json` is active data. Do not delete it as a “legacy file”.

Persisted files carry a `schemaVersion` and decode tolerantly (unknown enum values fall back per-field instead of invalidating the whole file), so newer builds always read older data.

The run log records event metadata such as provider name, response length, and timing. It is not designed to store conversation text, but provider error details may contain limited remote response data.

See [PRIVACY.md](PRIVACY.md) for the data boundary.

## Privacy boundary

Parrotlet has no account system and no built-in cloud backend.

The following is sent to the configured LLM provider:

- your chat messages;
- conversation summary needed to continue long sessions;
- selected text and surrounding context when you use lookup;
- the selected model and request options.

The following stays local:

- conversation files;
- word bookmarks;
- settings;
- run log;
- API key (in the macOS Keychain).

The app does not request microphone or speech-recognition permission.

## Current limitations

- Experimental status; pre-1.0.
- The app is signed with a self-signed certificate and **not notarized**: on other Macs, downloaded builds require right-click → Open. Proper Developer ID notarization is planned.
- Settings and UI copy are partly Chinese-first.
- Apple Silicon only.

## Roadmap

- Notarized Developer ID release pipeline.
- Safer persisted-summary boundaries and better long-session memory.
- More offline provider contract tests.

## Project layout

```text
Sources/Parrotlet/
├── AppEnvironment.swift
├── ParrotletApp.swift
├── Features/
│   ├── Chat/
│   ├── Settings/
│   └── WordBook/
├── LLM/
├── Models/
├── Storage/
└── Support/
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

Released under the [MIT License](LICENSE).
