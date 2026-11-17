# AmusoKit, for Sonos speakers

AmusoKit plays Apple Music on Sonos speakers from a MusicKit app, the way the Sonos app itself
does: the app hands the players Apple Music identifiers, and the players fetch the music from
Apple themselves. Nothing goes through the phone or the Mac, so lossless and Dolby Atmos play as
the Sonos app would play them, and the music keeps playing when the app is closed.

It is the Sonos layer of [Amuso](https://amuso.app), published so that other apps can do the
same. It talks to the players over their local UPnP API on port 1400: no Sonos account, no cloud,
no developer key.

> AmusoKit is an independent project. It is not affiliated with, endorsed by or sponsored by
> Sonos, Inc. or Apple Inc. Sonos is a trademark of Sonos, Inc.; Apple Music, MusicKit and
> Dolby Atmos are trademarks of their owners.

## What it does

- **Finds the household**: Bonjour (`_sonos._tcp`) and the players seen before, asked together,
  the first household with groups winning, so that an unplugged or sleeping speaker holds no one
  up (`HouseholdSearch`, `BonjourBrowser`, `KnownPlayers`).
- **Knows the household's shape**: groups, their coordinators, stereo pairs and subs, kept current
  by events (`Household`, `ZoneGroup`, `Player`, `TopologyMonitor`).
- **Runs one group live** (`SonosGroupSession`): transport state, track, position, play mode,
  group and member volumes, and what the players render (`StreamInfo`: bit depth, sample rate,
  lossless, Dolby Atmos), from UPnP events, with polling where events can't reach the app.
- **Plays Apple Music**: replaces or adds to the group's queue with catalog songs, albums and
  playlists or items of the user's library, sixteen per call, starting playback as soon as the
  song asked for is in; tunes to Apple Music stations (`AppleMusicItem`, `AppleMusicURI`).
- **Plays, pauses, skips, seeks, shuffles and repeats, and sets the volume** of the group or of
  one speaker.

## Requirements

- iOS 18, iPadOS 18 or macOS 15, and Swift 6.2.
- Sonos players on the same local network. It was developed with an Era 300 pair and a Sub Mini.
- An Apple Music account linked to the Sonos household in the Sonos app. Playback uses the
  household's account, not the device's.

## Installation

```swift
dependencies: [
  .package(url: "https://github.com/bourquep/AmusoKit.git", from: "0.1.0"),
],
```

In Xcode, **File › Add Package Dependencies…** with the same URL.

### What the app must set up

- **iOS and iPadOS**: `NSLocalNetworkUsageDescription`, saying why the app talks to the speakers,
  and `NSBonjourServices` with `_sonos._tcp`, in `Info.plist`. Without the Local Network
  permission every connection to a player fails, as if the device were offline.
- **macOS**: in the App Sandbox, outgoing connections (client) for the commands and **incoming
  connections (server)** for the event listener, which the players connect to. macOS 15 and later
  also ask for the Local Network permission, so the same `NSLocalNetworkUsageDescription` applies.
- **The user**: UPnP has to stay on in the Sonos app's **Connection Security** settings (it is
  on by default). When it is off, every call fails; tell the user where to turn it back on.

### Limits

- **Only Apple Music.** Catalog songs, albums and playlists, items of the user's library by their
  library identifiers, and stations. Local files, other streams or audio the app makes would need
  the app to serve them over HTTP, which AmusoKit doesn't do.
- A library song with no catalog match (an upload, or a song withdrawn from Apple Music) has no
  identifier the players can find.
- Live radio stations (Apple Music 1 and the like) are refused by the players.
- Plays started this way don't show up in Apple Music's Recently Played.

## Using it

```swift
import AmusoKit

let client = SoapClient()
let gena = GenaClient()

// Find the household: the players seen last time first, then whatever Bonjour finds.
let outcome = await HouseholdSearch.first(
  known: knownPlayers.endpoints,
  discover: { await BonjourBrowser.discoverEndpoints() },
  household: { endpoint in
    try await ZoneGroupTopologyService(client: client, endpoint: endpoint).household()
  }
)
guard let found = outcome.household else { return }
// Each player's device description says, among other things, whether it can play Dolby Atmos.
let household = await ZoneGroupTopologyService.describing(found, session: client.session)
knownPlayers.remember(household)
guard let group = household.group(named: "Living Room"), let coordinator = group.coordinator else {
  return
}

// Receive the players' events, and hand each to whoever owns it.
let listener = try EventListener()
_ = try await listener.start()
let host = await LocalAddress.reaching(coordinator.endpoint)
let callback = host.flatMap { listener.callbackURL(host: $0) }

let session = SonosGroupSession(group: group, client: client, gena: gena, listener: listener)
Task {
  for await notification in listener.notifications where session.owns(notification) {
    session.apply(notification)
  }
}
await session.start(callback: callback)

// Play an album's songs from the third, then add a song from the library after them.
let items = songIDs.map { AppleMusicURI.enqueueItem(.song($0), style: .serviceOnly) }
try await session.replaceQueue(with: items, startIndex: 3)
try await session.enqueue([AppleMusicURI.enqueueItem(.libraryTrack(libraryID), style: .serviceOnly)])
await session.setGroupVolume(25)
```

`SonosGroupSession` is `@Observable` and on the main actor: show `session.transport` (state,
track, position, play mode, source), `session.volume`, `session.queueFillProgress` and
`session.lastError` straight from SwiftUI. When the selected room's group changes, call
`session.update(group:callback:)`; when the app comes back to the foreground on iOS, call
`resume(callback:)` on the session and the `TopologyMonitor`, since a suspended app's
subscriptions lapse.

The identifiers are the ones MusicKit gives: `Song.id` for a catalog song, a library song's `id`
(`i.…`) for the library, `Station.id` (`ra.…`) for a station, which is tuned to with
`session.tune(to:)` instead of being enqueued. Pass the songs rather than their album or playlist
when the queue should show them at once and play from any of them.

## How it talks to the players

Every player answers UPnP/SOAP on port 1400, the API that SoCo (Home Assistant), node-sonos and
Sonos's own older controllers use. Sonos calls it "the older UPnP protocol, which is no longer
actively maintained". The alternatives don't fit: Sonos's cloud Control API cannot hand a player
an Apple Music identifier for a third party, and the port-1443 local API needs a key that Sonos
doesn't give out.

| Service | Control path | For |
|---|---|---|
| `AVTransport` | `/MediaRenderer/AVTransport/Control` | queue, transport, position, play mode |
| `RenderingControl` | `/MediaRenderer/RenderingControl/Control` | a player's volume and mute |
| `GroupRenderingControl` | `/MediaRenderer/GroupRenderingControl/Control` | a group's volume and mute, on the coordinator |
| `ZoneGroupTopology` | `/ZoneGroupTopology/Control` | the household: groups, coordinators, members |
| `ContentDirectory` | `/MediaServer/ContentDirectory/Control` | the queue (`Q:0`) |

Transport and queue commands go to the **group coordinator**; a stereo pair is one zone whose
second speaker is `Invisible` in the topology. Faults come back as HTTP 500 with a `UPnPError`
code (`SonosError.fault`).

**Discovery.** Players advertise `_sonos._tcp` over Bonjour, which `NWBrowser` browses on iOS
without the multicast entitlement SSDP would need. The TXT record's `location` is the device
description's URL, so nothing has to be resolved; one player's `ZoneGroupTopology` then describes
the whole household. Known players are asked 250 ms apart without waiting for an answer, while
Bonjour browses; the first household with groups wins and the rest are cancelled.

**Events.** The session subscribes (GENA) to `AVTransport`, `GroupRenderingControl` and
`ContentDirectory` on the coordinator and to `RenderingControl` on each visible member, with a
callback to `EventListener`, an `NWListener` on an ephemeral port. The callback's host is the
local address of a connection to a player, so that it is on the interface the players can reach.
Subscriptions are granted 300 seconds and renewed at 85 % of that.

- The first `NOTIFY` after subscribing carries the service's whole state, so the session reads
  it at the start without a round of `Get…` calls.
- A change arrives within the second. Commands are optimistic (the state shows `TRANSITIONING`
  at once) and read back after 1.5 s when no event confirmed them.
- The event's track metadata says what the player renders, in `r:streamInfo`:
  `bd:16,sr:48000,c:11,l:0,d:1` is bit depth, sample rate, a codec number (11 for Dolby Digital
  Plus), lossless, and Dolby Atmos. `GetPositionInfo` leaves it out. `StreamInfo` parses it.
- Position is not evented: the session reads `GetPositionInfo` when the state or the track
  changes and every 30 seconds while playing, counts forward in between (`PositionClock`), and
  reads the whole transport again when the state isn't the one it holds, in case an event was
  lost.
- When the listener can't start or the subscriptions lapse, the session polls, every second in
  the foreground and every five in the background (`isInBackground`), and tries to subscribe
  again every minute.

## Apple Music

Sonos plays Apple Music through its own Apple Music service (service id 204, service type 52231 =
204 × 256 + 7). A controller enqueues an item with a URI that names the Apple Music object, and
DIDL-Lite metadata whose `desc` element carries the token `SA_RINCON52231_X_#Svc52231-0-Token`.
The player resolves the stream from Apple itself, with the account linked to the household, so
the quality is the player's decision, not the controller's.

Four URI styles are seen in the wild, and the players accept all of them (`AppleMusicURIStyle`):

| Style | Song | Album |
|---|---|---|
| The Sonos app's own (`.sonosApp`) | `x-sonos-http:song%3a<id>.mp4?sid=204&flags=8224&sn=<sn>` | `x-rincon-cpcontainer:1004206calbum%3a<id>?sid=204&flags=8300&sn=<sn>` |
| Service only (`.serviceOnly`) | `x-sonos-http:song%3a<id>.mp4?sid=204` | `x-rincon-cpcontainer:1004206calbum%3a<id>?sid=204` |
| Bare (`.bare`) | `song%3a<id>` | `x-rincon-cpcontainer:1004206calbum%3a<id>` |
| Service and serial (`.serviceAndSerial`) | `x-sonos-http:song%3a<id>.mp4?sid=204&sn=<sn>` | `…?sid=204&sn=<sn>` |

`sn` is the household's serial number for the Apple Music account. Use **`.serviceOnly`**: the
player rewrites every form into its own (`sn` filled in, `flags=8232`), so nothing has to be
learned from the household. What was found on an Era 300 pair, enqueueing Dolby Atmos albums:

- Every style plays, and **Dolby Atmos plays**, whether songs are enqueued one by one, sixteen to
  an `AddMultipleURIsToQueue` call, or as an album container.
- **Library songs play by library identifier** (`librarytrack%3ai.…`), the identifiers
  MusicKit's `MusicLibraryRequest` returns, as the Sonos app does. No catalog lookup is needed.
  `AppleMusicItem` also builds library albums (`l.…`) and playlists (`p.…`) as containers, which
  haven't been tried on a player.
- **Metadata can be minimal.** The player looks up the title, artist and album of every entry,
  so the DIDL-Lite sent needs only the item id, the class and the token.
- **The URI doesn't say whether Atmos plays**; `r:streamInfo` in the events does.
- **A batch is all or nothing.** One identifier the player can't find refuses the whole
  `AddMultipleURIsToQueue` call with UPnP error 800, and none of its items go in. The queue fill
  splits a refused batch in halves to find the songs at fault, leaves them out
  (`QueueFillOutcome.refused`) and goes on. Error 800 is also the answer to metadata whose item id
  doesn't match its URI (library ids contain dots: never cut one at a `.`), and to every song when
  the household's Apple Music sign-in has lapsed, which signing in again in the Sonos app fixes.
- **A station is tuned to, not enqueued**: `SetAVTransportURI` to
  `x-sonosapi-radio:radio%3a<ra.id>?sid=204`, then `Play`. The queue is left alone, and Next skips
  within the station. An artist's station is `ra.<artist id>`, a song's `ra.<song id>`.
- The players say nothing about the Apple Music account they play with, so a household signed in
  to another account or country can't be told apart before playing.

## Diagnostics

`SonosGroupSession.fillJournal` keeps the last few queue fills in memory, call by call (counts,
timings, retries and errors), for an app's diagnostics or a support request. Logs go to the
unified log under the subsystem `app.amuso.AmusoKit`; the queue fill logs under the category
`Queue`.

## Development

```sh
swift build
swift test
swiftlint
```

The tests use Swift Testing, against responses captured from real players in
`Tests/AmusoKitTests/Fixtures/`, with the household's identifiers, addresses and room names
replaced by made-up ones. The package builds in the Swift 6 language mode with the main actor as
the default isolation; types that are not UI state are marked `nonisolated`.

## License

MIT. See [LICENSE](LICENSE).
