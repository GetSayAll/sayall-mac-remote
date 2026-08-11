# SayAllMacRemote

Private Swift Package containing the Mac-side remote connection components used
by SayAll applications.

## Products

- `SayAllMacRemoteCore`: nearby phone listener, web relay client, wire protocols,
  remote button types, and web audio jitter buffering.
- `SayAllMacRemoteUI`: SwiftUI session view built on the Core session state.

## Requirements

- macOS 13 or later
- Swift 5.9 or later

## Integration boundary

The package owns transport and protocol types. Host applications remain
responsible for permission prompts, button execution, audio output, application
logging, and localized strings. These responsibilities are connected through
callbacks and the public UI model/localization interfaces.

## Development

```sh
swift test
swift build -c release
```

This repository is private and distributed under the terms in `LICENSE`.
