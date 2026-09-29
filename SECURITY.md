# Security Policy

## Supported status

This project is experimental. Security fixes are best-effort while the product is in active development.

## Reporting a vulnerability

Please contact the repository owner through a private GitHub security advisory or another private channel listed in their profile.

Do not open a public issue for a vulnerability, API key, or exploitable provider content.

Include:

- affected commit;
- macOS version and CPU architecture;
- reproduction steps;
- impact;
- logs with secrets removed.

## Security expectations

- Remote LLM endpoints must use HTTPS.
- Plaintext HTTP is limited to loopback providers.
- API keys are stored locally in `config.json`; current files are tightened to `0600`.
- Chat, bookmark, and configuration data remain local.
- The app does not request microphone or speech-recognition permission.
- Model output is not connected to shell execution, file deletion, or system-settings tools.

## Known limitations

- API keys are not yet in Keychain.
- Builds are ad-hoc signed and not notarized.
- Swift 6 typechecking is enforced; normal compilation still uses the default language mode.
- Custom provider endpoints require user trust; conversation content and the API key are sent to the configured origin.
