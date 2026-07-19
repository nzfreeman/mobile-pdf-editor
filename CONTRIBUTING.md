# Contributing to Mobile PDF Editor

Thank you for considering a contribution.

## Before you start

- Search existing issues before opening a new one.
- Use an issue to discuss large features or breaking changes first.
- Never commit API keys, signing keys, OAuth secrets, user documents, or personal data.

## Development setup

1. Install the current stable Flutter SDK and Android Studio.
2. Clone the repository.
3. Generate the Android platform project if it is not present:

   ```bash
   flutter create . --platforms=android --org com.nzqueenbee --project-name mobile_pdf_editor
   ```

4. Install dependencies and verify the project:

   ```bash
   flutter pub get
   flutter analyze
   flutter test
   ```

5. Run the app:

   ```bash
   flutter run
   ```

## Pull requests

- Create a focused branch for one change.
- Keep unrelated formatting changes out of the pull request.
- Add or update tests when practical.
- Run `dart format .`, `flutter analyze`, and `flutter test` before submitting.
- Complete the pull request template and explain user-visible changes.
- Do not include generated build output, credentials, signing files, or private PDFs.

## Commit messages

Use clear, imperative messages, for example:

- `Add page rotation controls`
- `Fix signature placement on scaled pages`
- `Update Android build workflow`

## Reporting security issues

Do not open a public issue for a vulnerability or exposed credential. Follow the private reporting instructions in `SECURITY.md`.

## License

By contributing, you agree that your contribution will be licensed under the MIT License.
