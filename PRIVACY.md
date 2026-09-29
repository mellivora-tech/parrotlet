# Privacy Notice

Parrotlet is a local-first macOS menu-bar application. It has no account system and no product-owned backend.

## Data sent to your configured provider

When you use chat or lookup, the app sends the required request content to the active LLM provider:

- your messages;
- recent conversation context;
- a summarized earlier-conversation context when needed;
- selected text and its surrounding conversation context;
- model name and request options;
- API authentication header.

Your provider controls retention, logging, and processing on its service. If you configure a custom endpoint, inspect and trust that endpoint before sending an API key or conversation content.

## Data stored locally

The application-support folder contains:

- `config.json`: provider settings and app preferences (no secrets — API keys live in the macOS Keychain, one entry per provider);
- `chat-sessions.json`: conversations and summaries;
- `words.json`: bookmarked lookup explanations;
- `app.jsonl`: local event log.

The app writes `config.json` with `0600` permissions.

## Logs

The run log records operational metadata such as event names, provider name, lengths, status, and timing. It is not intended to contain chat text. Remote provider errors may include a short error body and therefore remain externally influenced input.

## Microphone and speech recognition

Parrotlet does not request microphone or speech-recognition permission and does not perform speech recognition.


## Deleting data

Quit Parrotlet and remove:

```text
~/Library/Application Support/Parrotlet/
```

This deletes local settings, conversations, bookmarks, logs, and legacy voice-pack data. It cannot delete data already sent to your LLM provider.
