# simdrive docs

What the code alone does not tell you: why simdrive works the way it does, and what was learned building it. For usage, see the [README](../README.md); for contributing, [AGENTS.md](../AGENTS.md).

- [Architecture](architecture.md): modules, the request path, the daemon, and which transport each capability uses.
- [Design decisions](design-decisions.md): choices, their reasons, and the alternatives that failed.
- [Private APIs](private-apis.md): the reverse-engineered interfaces, payloads and values simdrive depends on.
- [Device behavior](device-behavior.md): how simulators, runtimes and devices behave under automation.
- [Testing](testing.md): the evaluation matrix, the probe app, and how to keep results trustworthy.
- [Open questions](open-questions.md): what is unverified or unexplained.

Built with Xcode 27.0 and 27.2 on macOS 26. Facts marked as observed were measured on those versions and may change.
