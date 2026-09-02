# Vendor

Vendored copies of third-party code used by Dynamic Island.

## MediaRemoteAdapter

Based on [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter)
(Swift package fork of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)).

**Why:** Starting with macOS 15.4, `mediaremoted` denies Now Playing reads to
third-party apps that lack private Apple entitlements. Direct
`MRMediaRemoteGetNowPlayingInfo` returns `nil` from this app. Apple-signed
`/usr/bin/perl` can still load a helper dylib that talks to MediaRemote.

**How we use it:** A Run Script build phase compiles `CIMediaRemote` into
`libMediaRemoteAdapter.dylib`, copies `run.pl` into the app Resources, and
`NowPlayingService` polls via `/usr/bin/perl run.pl <dylib> get`.
