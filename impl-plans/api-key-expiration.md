# API key expiration implementation

1. Keep API key administration in the server's existing client CLI commands.
2. Add date/never issuance options and report expiration in issue/list output.
3. Add nullable expiration to the credential model and schema v24, upgrading
   every supported store version while retaining permanent existing keys.
4. Validate canonical Gregorian dates in AppCore and reuse validation in the CLI.
5. Enforce inclusive UTC dates, revocation, and enabled-account checks during
   authentication, using a single server time sample.
6. Verify CLI behavior, the UTC boundary, rejected requests' last-use state,
   migration preservation, and existing schema tests; run build and SwiftLint.
7. Update the command reference and README with server ownership and UTC semantics.

## Completion evidence

- `swift test --filter 'APIClientExpirationTests|NoteStoreSchema|cliClientIssue|NoteUserTests'`:
  52 XCTest tests and 2 Swift Testing tests passed.
- `swift test --skip-build --filter 'NoteStoreSchemaVersion22Tests|NoteStoreSchemaVersion23Tests'`:
  10 migration tests passed, including preserved legacy credential authentication.
- `swift test --filter APIClientExpirationTests`: 3 tests passed after the final
  change to sample production time inside the authentication transaction.
- `swift build` passed. `swiftlint --quiet` exited 0 with three existing warnings
  in unrelated files. `git diff --check` passed.
