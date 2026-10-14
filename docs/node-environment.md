# Node environment preparation

Users can register startup commands such as `npm run dev`, `yarn dev`, or `pnpm dev`. Stackvale prepares the Node environment before executing these commands, without changing the saved command or the user's global Node version.

At each start, Stackvale looks in the service's working directory, then its ancestors up to the Git repository root. At each directory, the first declaration wins:

1. `.nvmrc`: a version or nvm alias, including `lts/*`.
2. `.node-version`: a version or nvm alias.
3. `package.json` → `engines.node`: a stable-version range.

For `engines.node`, Stackvale selects the highest compatible version already installed in nvm. Supported ranges include exact and partial versions, wildcards, comparisons, caret and tilde ranges, hyphen ranges, and alternatives joined by `||`. Prerelease ranges and unsupported syntax produce an explicit error; use `.nvmrc` to pin those versions.

Stackvale loads nvm from `NVM_DIR`, the default nvm directory, or a standard Homebrew installation, then runs `nvm use` in the service process before the startup command. nvm and the required Node version must already be installed. Stackvale does not download runtimes or install dependencies. Preparation failures are shown in the service log and prevent the startup command from running.

Commands with no Node declaration, non-Node commands, and Docker Compose services retain their existing execution behavior. This preparation targets nvm; other version managers are not configured automatically.

## Verification

Run the focused checks from the repository root:

```sh
swiftc -module-cache-path /tmp/stackvale-swift-module-cache \
  Stackvale/NodeCommandEnvironment.swift Tests/NodeCommandEnvironmentTests.swift \
  -o /tmp/stackvale-node-tests
/tmp/stackvale-node-tests
make build
```

The checks use isolated Node/nvm fixtures to cover upgrades, downgrades, version ranges, inherited configuration, missing versions, and command quoting.
