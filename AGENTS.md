# Agent Guidelines

- Keep changes small, focused, and consistent with the existing Swift/Xcode project structure.
- Prefer simple SwiftUI/AppKit code unless a task explicitly calls for more architecture.
- Do not commit generated build products or local Xcode user state.
- Always use Conventional Commits for commit messages.
- After every task that changes Swift, Xcode project settings, assets, or build-affecting files, run the build command: `make build`.
- You do not need to run `make build` for changes that only touch docs or developer tooling files such as `Makefile`, unless the change can affect the app build.
- For the macOS release process and public repository policy, read
  [`README.md`](README.md).
