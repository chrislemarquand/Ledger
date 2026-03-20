# Dependency Policy

## Pinning

- Shared cross-repo dependencies (for example `SharedUI`) must be pinned to a released tag.
- Do not ship with local path package references.

## Update Procedure

1. Update package requirement in Xcode or project config.
2. Resolve dependencies:

```bash
xcodebuild -resolvePackageDependencies -project Ledger.xcodeproj -scheme Ledger
```

3. Commit the lockfile:

- `Package.resolved`

4. Run release gates:

```bash
./scripts/release/release_check.sh
```

5. Include dependency bumps in release notes/changelog.
