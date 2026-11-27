# Private APIs

What simdrive calls, and what was learned about it, on Xcode 27.0 and 27.2. Names are as resolved at run time; any may change with an Xcode update. `doctor` exercises most of them.

## CoreSimulator

Loaded from `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`.

- `SimServiceContext +sharedServiceContextForDeveloperDir:error:`, then `-defaultDeviceSetWithError:`, then `devicesByUDID` (`[UUID: SimDevice]`). One context per developer directory.
- `SimDevice` getters: `name`, `stateString` (`Booted`), `runtimeIdentifier` (`com.apple.CoreSimulator.SimRuntime.iOS-18-3`), `deviceTypeIdentifier`, `lastBootedAt`, `dataPath` (the host directory holding the guest's `/tmp`, `/var` and home directories).
- `-lookup:error:` returns a caller-owned Mach send right to a guest service, or 0 or `UInt32.max` when there is none. Probing for a service means looking it up and deallocating the right.
- `-postDarwinNotification:error:` posts in the guest, as `notifyutil -p` there would.
- `-currentUIInterfaceStyle`, `-currentContentSizeCategory` and `-currentIncreaseContrastMode` return `Int`s numbered from 1 (light and dark; extra small to accessibility extra extra extra large; off and on), and -1 on tvOS. `-setUIInterfaceStyle:error:` and `-setContentSizeCategory:error:` take those numbers, and `-setIncreaseContrastEnabled:error:` a `BOOL`.
- `-sendAccessibilityRequestAsync:completionQueue:completionHandler:` carries AXPTranslator's requests to the guest. CoreSimulatorBridge answers them one at a time and never withdraws one its sender stopped waiting for, so later requests queue behind it (idb's finding); simdrive keeps one in flight per device and waits 5 s for each (F33).

### Interface orientation

- Chain: `SimDevice.io`, its `ioPorts`, the port whose `portIdentifier` is `com.apple.framebuffer.server`, its `descriptor` (a `SimScreenAdapter`), then `-enumerateScreensWithCompletionQueue:completionHandler:`. Each screen's `screenProperties` (`SimScreenProperties`) has `screenID` and `uiOrientation`, both `UInt32`. A round trip takes milliseconds.
- The ports are ROCK remote proxies. `value(forKey:)` fails on them; `perform(_:)`, and `method(for:)` cast to a C function for scalars, work.
- `uiOrientation`, as `simctl io enumerate` labels it: 0 Ambiguous, 1 Portrait, 2 Portrait Upside Down, 3 Landscape Left, 4 Landscape Right. The names are UIKit's interface orientations, but the numbers are not `UIInterfaceOrientation`'s, which swaps 3 and 4.
- Observed: device `landscape-left` gives 4, `landscape-right` gives 3, since the interface counter-rotates the device. 2 was never observed.
- `screenID` equals the `simctl` display index. A single-display device's screen is 1.
- `screenProperties.backlight.state` (`UInt32`, read as `Int32`) is -101, unknown, on every screen early in a boot, and 2 once a panel has started; 1 is dimmed and 0 off. `doctor` reports it per screen as `backlight`.
- `SimDevice -darwinNotificationGetState:name:error:` (a `uint64_t *`, an `NSString`, an `NSError **`; returns `BOOL`) reads a Darwin notification's state in the guest, as `notifyutil -g` does there. `com.apple.springboard.lockstate` is 1 while locked; `doctor` reports it as `locked`, and it matched `notifyutil` through a lock and an unlock. simdrive waits for any screen other than -101 before its first accessibility read (F15). Settled devices: an iPhone (iOS 17.0 and 27.2) reports 2; a Duo 2 on its cover panel and -101 on its inner one; an Apple TV (tvOS 18) -101 always, so simdrive skips the wait there.

### Screenshots

- simdrive reads each screen's framebuffer in process. The `ioPorts` whose `portIdentifier` is `com.apple.framebuffer.display` have `SimScreen` descriptors, with the same `screenProperties` plus `powerState` (1 is on) and `framebufferSurface`, a BGRA `IOSurface` in the panel's native orientation. Copying it takes about 12 ms.
- `simctl` turns that image counterclockwise by `uiOrientation`: 4 a quarter turn, 3 three, 2 two (unverified), others none. `maskedFramebufferSurface` rounds the corners, which `simctl` does not.
- The surface matches `simctl` pixel for pixel on the iPad, the Apple TV and the Duo's open cover panel. It also shows the Dynamic Island and the Duo's closed-cover camera hole, which `simctl` masks, and lacks a 4×4 black square `simctl` draws in the Duo inner panel's corner.
- Without a powered-on BGRA surface, simdrive falls back to `simctl io <udid> screenshot --type=png [--display=N] <path>`. A multi-display device refuses without `--display` and lists its panels as `--display=N <name> (<role>) <width>x<height>`; simdrive parses that listing to find them. The Duo's cover panel has the role `primary`, the inner panel `primary-1`.
- `simctl` itself calls the `com.apple.display.captureservice` port's `SimScreenCaptureService`: `captureScreenshotFromScreen:maskPolicy:imageType:outputFile:completionQueue:completionHandler:`, with a `SimScreen`, mask 0 and type 0 for PNG, and an `NSString` path. It takes about 350 ms. Any other `outputFile`, such as an `NSFileHandle`, crashes SimRenderServer and shuts the simulator down.

## Guest services

- A Mach send right from `lookup:error:` becomes an XPC connection through `xpc_endpoint_create_mach_port_4sim` and `xpc_connection_enable_sim2host_4sim`, resolved with ABIBridge from libxpc. A created endpoint owns the right.
- libxpc requires a connection to be activated before its release, even one being discarded.
- Messages are XPC dictionaries with the feature identifier, a message type and a payload, under field names read from `CoreDeviceUtilities.HIDXPCServiceEvent`'s static getters. Payloads are CoreDeviceUtilities values encoded with `Mercury.XPCObjectEncoder`; replies decode with `Mercury.XPCObjectDecoder`, and an error field holds an `NSErrorContainer`.
- The guest removes the services a connection created when the connection ends, and drops events it had not yet activated. Cancelling a connection also discards unsent messages, so simdrive waits on a barrier after each input.
- The guest matches a new service shortly after it appears and drops events sent before; simdrive waits 400 ms. A guest service answers a request of `{"isBarrier": true}` with an empty dictionary once it has handled the connection's earlier messages, on iOS 17.0 to 27.2 and tvOS 26.2; the first answer on a new connection can take 1.5 s. On iOS 27.2 the guest still drops a connection's events when it ends right after that answer, on iPhones and the Duo; 100 ms after it was enough in 60 tries, and simdrive waits 300 ms. iOS 17.0 needs no wait.

| Feature (`com.apple.coredevice.feature.` …) | Message type | Payload |
| --- | --- | --- |
| `remote.universalhidservice` | `Request` | `DDIUniversalHIDServicePayload.Request`: `createService(HIDServiceDescriptor)`, `send(Data, HIDServiceID)`, `removeService(HIDServiceID)` |
| `remote.hid.digitizer` | `IndigoDigitizerEvent` | `IndigoDigitizerEvent(pointOne:pointTwo:eventType:edge:target:)` |
| `remote.universalhidservice` (buttons) | `Request` | A `HIDServiceType.mainScreenButtons` service, created with its `descriptor()` given the type's `serviceID`, sent `CustomButtonReport(usage: HIDUsage(page:usage:), down:).report`. Carries the iPhone's buttons and, on tvOS 18, the Apple TV Remote's (observed). |
| `remote.hid.button` (`button --legacy`) | `IndigoButtonEvent` | `IndigoButtonEvent(usagePage:usageCode:state:)`. Xcode 27.3 (CoreDeviceUtilities 699.2) removed the type, so it is resolved only when `--legacy` asks for it. |
| `remote.devicecontrol.orientation` | `OrientationRequest` | `currentOrientation` or `changeOrientation(DeviceOrientation)`; the reply is `OrientationInfo` |

### Keyboard

- The service comes from `CoreDevice.HIDServiceDescriptor.mainKeyboard()`, passed through `setSoftwareKeyboard(false)`: the guest takes input only from a hardware keyboard, which the main keyboard is not by default.
- Reports come from `UniversalHIDKit.EventObserver<NSEvent>` (`init(eventMask:)`, `processEvent(_:)`), as DeviceHub makes them. Its results are `(HIDReport, senderID)` pairs.
- Two `UniversalHID` modules exist: the system's, which UniversalHIDKit uses, and a copy bundled in `CoreDevice.framework/Versions/A/Frameworks`, whose `HIDReport` CoreDevice's services take. Their types are distinct, so reports cross as `Data`.
- The observer reads a key from its key code alone, and keeps modifier state per observer, so each keyboard needs its own.
- The guest decodes keys with its hardware keyboard layout. A runtime's layouts are in `System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle`: `USBKeyboardLayouts.plist` maps a name such as `German` to `KeyLayoutFileName`, a `uchr` file in `uchrs/` that `UCKeyTranslate` reads by HID usage rather than Mac key code. The active one follows from `.GlobalPreferences` (`AppleKeyboards`, `AppleKeyboardsExpanded`, `AppleLanguages`), `com.apple.keyboard.preferences` (`KeyboardLastUsed`) and the runtime's `TextInput_<language>.bundle/InputMode_<language>.plist` (`HWLayouts`, `UIKeyboardDefaultLanguageInputModes`), by AXe's rules. Typing German, French and Russian text matched on iOS 27.2.

### Digitizer

- Points are unit coordinates of the target panel in its native orientation, from the top-left. Single-display touchscreens are portrait natively; a Duo panel's native size is in the `simctl` listing.
- `eventType`: `start`, `position`, `end`. `edge`: `none`, `top`, `bottom`, `left`, `right`; system edge gestures, such as going home, need a touch that starts with an edge.
- `target`: `mainScreen` on single-display devices, `display<N>` with the `simctl` index on the Duo.
- While one client holds the digitizer, the guest drops other clients' touches.

### Buttons

Consumer usage page 0x0C, with usages as the guest maps them, not as the HID tables name them:

| Button | Usage | Note |
| --- | --- | --- |
| `home` | 0x40 (HID's Menu) | On tvOS, the TV button |
| `lock` | 0x30 (Power) | On tvOS, opens Control Center |
| `menu` | 0x223 (HID's AC Home) | The remote's Back |
| `select` | 0x41 | |
| `up`, `down`, `left`, `right` | 0x42–0x45 | |
| `play-pause` | 0xCD | |
| `volume-up`, `volume-down` | 0xE9, 0xEA | |
| `siri` | 0xCF | |
| `channel-up`, `channel-down` | 0x9C, 0x9D | |

### Orientation

`OrientationInfo.currentDeviceNonFlatOrientation` is the last orientation that was not flat, which the interface follows; `currentDeviceOrientation` may also read `faceUp`, `faceDown` or `unknown`. Raw values are `portrait`, `portraitUpsideDown`, `landscapeLeft`, `landscapeRight`.

## CoreDevice

Loaded from `/Library/Developer/PrivateFrameworks/CoreDevice.framework`.

- `DeviceManager(serviceConnection: CoreDeviceService.sharedConnection, allowedDeviceVisibilityClasses: [.default, .simulators])`, then `awaitFullInitialization()`. One per process.
- A simulator's `RemoteDevice` is found by matching `deviceInfo.udid`; `DeviceManager.devices` is keyed by a CoreDevice identifier, not the UDID.
- `RemoteDevice.getImplementation(for: CapabilityStaticMember<C>())` returns a capability's implementation; `supportsFeature(identifiedBy:)` checks for it first.
- Capabilities throw `CoreDeviceError` with typed throws. Binding them needs a sample value of that type, `CoreDeviceError.ioError`.

### Hinge

- Present only when CoreSimulator lists more than one screen for the device (the iPhone Duo), and the device supports `remote.hid.vendordefined`, `monitormotion` and `remote.universalhidservice`, and `motionManager().supportsHingeAngle` is true.
- Reading: `MonitorMotionProtocol.motionManager().monitorHingeAngle(config: HingeAngleStreamConfig(changeThreshold:updateInterval:))` returns an `AsyncThrowingStream<[DeviceHingeAngleSnapshot], Error>`; each snapshot has `isAngleValid` and `angle` (`Measurement<UnitAngle>`). The returned owner must stay alive while the stream is read.
- Setting: `HIDVendorDefined.send(usagePage: 0xFF61, usage: 0x5B, version: 0, data:)`, where `data` is an `IOCFSerialize` binary dictionary: `provider` `com.apple.Virtualization.VirtualMachines`, `source` `hinge-slider-control`, `type` `range`, `value` the angle in degrees.
- The hinge animates toward the angle and settles near it. simdrive sends 0, 130 and 180 and reads below 15° as closed and above 175° as open.
- No other path was found: `simctl`, `devicectl`, DeviceHub's strings, XCUITest and NeoSimulator's URL scheme (which only has `open-device`) have no hinge control.

### Pasteboard

- `PasteboardCapability` (`com.apple.coredevice.feature.pasteboard`): `currentPasteboardSnapshot(pasteboardName: "general", dataPolicy:)` and `setPasteboardContents(pasteboardName:pasteboardSnapshot:)`, as `devicectl device pasteboard` uses them.
- `PasteboardSnapshot(from: NSPasteboard, dataPolicy:)` and `write(to: NSPasteboard)` convert. `PasteboardDataInclusionPolicy.allResolved` includes every type's data, so neither side keeps promises the other must resolve.
- Swift initializers called through ABIBridge consume their arguments, so each capture needs its own copy of the policy, as each `EventObserver(eventMask:)` needs its own mask.

### Setting actions

CoreDevice declares guest actions that read and apply a setting as the Settings app does; `xcrun devicectl device info|settings appearance|voiceover` calls them. simdrive sends them straight to the guest service that performs them, as NeoSimulator does (`N:NeoSimulatorDeviceIO/CoreDevice/GuestSettingsActions.swift @c9710cf`), with no CoreDevice record. A warm read or change takes 30–370 ms, against about 3 s for `devicectl`, which starts CoreDevice in its own process.

- Each action is `CoreDeviceUtilities.<Get|Set><Name>ActionDeclaration`, with nested `Input` and `Output` types. Its static `identifier` names the action, and its static `executionLocation` is `.remoteDevice(<feature>)`, the guest Mach service to connect to. CoreDeviceUtilities 699.2 (Xcode 27.3) moved `executionLocation` to the `ActionDeclaration` protocol, so simdrive falls back to `CoreDeviceUtilities.ActionDeclaration.executionLocation` (unverified: no Xcode 27.3 here).
- The message is a dictionary of `CoreDevice.actionIdentifier`, `CoreDevice.deviceIdentifier` (the UDID), `CoreDevice.invocationIdentifier` (a new UUID), `CoreDevice.CoreDeviceDDIProtocolVersion` = 1, `CoreDevice.coreDeviceVersion` (CoreDevice's `CFBundleVersion` as `components`, `originalComponentsCount` and `stringValue`) and `CoreDevice.input`, the input encoded with `Mercury.XPCObjectEncoder`. The reply has `CoreDevice.output`, decoded with `Mercury.XPCObjectDecoder`, or `CoreDevice.error` with `domain`, `code` and `userInfo`.
- simdrive builds inputs from JSON with `JSONDecoder` resolved for the input type, and turns outputs into JSON with `JSONEncoder`, since the types are `Codable`.
- In use: `VoiceOver` (`voiceOverConfiguration.enabled`) and `ColorFilter` (`colorFilter` with `enabled`, `filterType` and `intensity`; `filterType` is a `DeviceColorFilter.FilterType` static member such as `deuteranopia`, which encodes as `{"name": "Deuteranopia", …}`). Also declared, unused: `ReduceMotion`, `ShowBorders`, `ReduceTransparency`, `LiquidGlassConfiguration` and `DeviceLookAndFeel` (I10).
- Runtimes: VoiceOver reads and changes on iOS 17.0, 26.5 and 27.2. The color filter reads on all three but changes only on iOS 27: older guests answer error 21049, "Color filter customization is not supported on this device". The guest refuses an intensity for grayscale.

## AccessibilityPlatformTranslation

Loaded from `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework`.

- `AXPTranslator.sharedInstance`, with `supportsDelegateTokens`, `accessibilityEnabled` and `bridgeTokenDelegate` set. The delegate must conform to `AXPTranslationTokenDelegateHelper`, which has no header, so simdrive adds it with `class_addProtocol`. The translator holds the delegate weakly.
- The delegate implements `accessibilityTranslationDelegateBridgeCallbackWithToken:`, returning a block that sends a request through `SimDevice` and waits for the reply; `accessibilityTranslationConvertPlatformFrameToSystem:withToken:`, which returns frames unchanged so they stay in guest points; and `accessibilityTranslationRootParentWithToken:`, returning nil.
- The token is the UDID, set on every translation object with `bridgeDelegateToken` before converting it with `macPlatformElementFromTranslation:`. It is more than a key for the delegate: with `<udid>/<UUID>` instead, SpringBoard's frontmost element read with an empty frame on iOS 27.2 (F24).
- The translator is a process-wide singleton with one delegate, so simdrive sets it once (`TranslationHub`), runs every read on one queue, and routes each request by its token to the session that registered it; a session opened after a reboot replaces the old one's route, as AXe and idb do with their dispatchers. `translationApplicationObjectForPid:` calls the delegate with a nil token, so the delegate's token parameters are optional and a tokenless request goes to the only session registered.
- `frontmostApplicationWithDisplayId:bridgeDelegateToken:` answers for the frontmost app whatever display ID it gets. Its translation's `pid` is the app's process; the element's label is its name, a single space for SpringBoard.
- `translationApplicationObjectForPid:` (an `int`) makes the translation of any process's application, which `macPlatformElementFromTranslation:` and the snapshot then read as they do the frontmost one (`tree --app`, I8). A suspended app does not answer.
- `AXPTranslatorRequest` has `setClientType:`. NeoSimulator's requests list covered elements only for client types 2–4; the testing snapshot simdrive reads lists them whatever the type (iOS 27.2, I8), so simdrive sets none.
- `objectAtPoint:displayId:bridgeDelegateToken:` hit-tests in points of the panel's native orientation; the display ID is the `simctl` index, 0 on single-display devices.
- The frontmost element's frame is the app's, in points. It turns with the interface on some devices and not on others; on the Duo's inner panel it stays portrait while element frames follow the landscape interface. On the Duo it does not span the screen, beside the system's status strip, so simdrive sizes the screen from the screenshot and `SimDeviceType.mainScreenScale` (3 on both Duo panels), falling back to the app's frame.
- The translator blocks while the guest answers, so it runs on that queue, never the main actor.
- A request still on that queue when the process exits can crash inside `AXPTranslator`. Only the daemon, whose session outlives the command, starts a background read to warm the guest's server; a `--no-daemon` run never does.
- XCTest's accessibility bootstrap (`XCTDaemonControl`, `XCUIAutomation`'s `loadAccessibilityWithTimeout:reply:`) was tried as a faster start and rejected: right after a boot it did not finish in time, slowed the first `tree` and once crashed the daemon. Measurements are in the backlog's I16.

### The snapshot attribute

- `_accessibilityProcessAttribute:parameter:` with `AXTestingSnapshotParameterizedAttribute` returns an element's subtree. Parameters: `attributes` (XCUITest's attribute numbers), `maxDepth`, `maxChildren`, `maxArrayCount`, `traverseFromParentsToChildren`.
- Numbers in use: label 2001, hint 2002, frame 2003, traits 2004, value 2006, activation point 2007, language 2008, is-accessibility-element 2016, URL 2020, custom actions 2036, has-focus 2094, expanded status 2114, heading level 2180, input labels 2186, container type 2187, class name 5003, minimum 5005, maximum 5006, numeric value 5011, identifier 5019, view controller class 5042, placeholder 5043, automation type 5058.
- Display 2123 returns the screen ID an element draws on (1 for the Duo's cover, 3 for its inner panel; 0 or missing when unknown). AXe asks each button for it in a separate request; the snapshot returns it for every node, and light reads ask for it only on devices with several displays.
- Others can crash the app or return whole subtrees. Visibility (2025) hit-tests every node and times out on large screens.
- Traits are `UIAccessibilityTraits` bits plus private ones, such as bit 33 on static text inside cells; simdrive keeps the public bits.
- Custom content is not in snapshots. Each element's `AXCustomContent` attribute returns it archived, unarchived as `[AXCustomContent]`.

## Guest preferences

- `simctl spawn <udid> defaults export <domain> -` prints a property list; `defaults write <domain> <key> -int|-float|-string <value>` writes. The same domain is a file on the Mac, `<dataPath>/Library/Preferences/<domain>.plist`, which shows a `defaults write` as soon as it returns (iOS 27.2, I30); simdrive reads it there, in milliseconds and with no guest round trip.
- Accessibility keys live in `com.apple.Accessibility`; the Liquid Glass tint is `UIViewGlassTintAmount` in `com.apple.UIKit`, a 32-bit float that defaults to 0.5 while unset, announced by `UIViewGlassTintAmountUpdateNotification`.
- Accessibility notifications are `com.apple.accessibility.<name>`; most have a `com.apple.accessibility.cache.<name>` counterpart. The pairs are in [`SettingCatalog.swift`](../Sources/SimDriveCore/Settings/SettingCatalog.swift); [AGENTS.md](../AGENTS.md) describes how to find new ones.

## Logs and crash reports

- `simctl spawn <udid> log show --style ndjson --start @<seconds>` and `log stream --style ndjson --type log --level <level> --timeout <seconds>`, with `--info` and `--debug` for `show`. Lines are JSON objects; simdrive reads those whose `eventType` is `logEvent`, using `timestamp` (`2026-11-12 16:05:29.405902+0000`), `messageType`, `eventMessage`, `subsystem`, `category`, `processImagePath`, `processID` and `senderImagePath`, the library that logged.
- Crash reports are `~/Library/Logs/DiagnosticReports/*.ips`: one JSON header line, then a JSON body. A simulator's have `coalitionName` `com.apple.CoreSimulator.SimDevice.<UDID>`, which matches them to the device.
- Body fields used: `procName`, `pid`, `captureTime` (`2026-11-12 13:54:50.9488 +0000`), `exception` (`type`, `signal`), `asi` (an image's strings), `faultingThread`, `threads[].frames` (`imageIndex`, `symbol`, `symbolLocation`, `imageOffset`), `lastExceptionBacktrace` and `usedImages[].name`.
- A report's extended attributes include `Signature`, by which ReportCrash recognizes a repeated crash.

## Physical devices

Learned in N35 on 2026-11-27 with Xcode 27.2 (CoreDevice 651.32): first in spikes, then through simdrive's own commands. It used an Apple TV 4K on tvOS 27.2.1, paired over the local network, and an iPhone 15 Pro on iOS 27.2.1 over USB, both with Developer Mode on.

- **Listing.** `PhysicalDevices.paired()` reads `DeviceInfo`'s `name`, `udid`, `productType`, `osVersion`, `state` and `visibilityClass`, whose raw value `simulators` marks a simulator's record.
- **Connecting.** `CoreDeviceRemote.open(physical:)` connects, and `Guest(physical:)` opens each feature with `remoteXPCConnection` behind a `RemoteDeviceLink`.
- **Settings and screenshots** go through `GuestActions`, named by CoreDevice's identifier.

- **The device's services.** Its developer disk image runs the guest's CoreDevice daemons: `dtuhidd`, `dthidd`, `dtconfigurationd`, `dtscreencaptured`, `dtdeviceinfod`, `dtappserviced` and others. The image's files live in `/Library/Developer/DeveloperDiskImages/{iOS,tvOS}_DDI`, each daemon's `RemoteServices` listing its features.
  - Each service requires a `com.apple.private.CoreDevice.*` entitlement of its peer. CoreDevice.framework's `CoreDeviceService.xpc` holds them, so an unentitled process that loads CoreDevice reaches them.
- **Reaching the device.** `DeviceManager.devices` lists paired devices, since simdrive's manager already admits `.default`.
  - `RemoteDevice.connect()` took 1.1 s cold and 30 ms warm.
  - `RemoteDevice.remoteXPCConnection(toFeatureIdentifiedBy:connectionMode:handlingEventsOn:)` with mode 0 took 30 ms. It returns an `OS_xpc_remote_connection`.
  - That connection is driven with RemoteXPC.framework's C functions: `xpc_remote_connection_set_event_handler`, `_activate`, `_send_message`, `_send_message_with_reply` and `_cancel`. Their block parameters escape.
- **The same messages as a simulator's guest.** simdrive's `GuestMessageCodec` messages worked unchanged on this connection.
  - The `{"isBarrier": true}` request answered with an empty dictionary: 200 ms first, then 26–80 ms.
  - `createService` with `HIDServiceType.mainScreenButtons` returned `serviceID`.
  - `CustomButtonReport` presses `menu` (which dismissed the screensaver), `left` and `right` moved focus, as screenshots showed.
  - No media stream was running. pymobiledevice3's note that UniversalHID needs one did not hold for buttons here.
- **The Apple TV's features.** It supports `remote.universalhidservice`, `remote.hid.button`, `remote.hid.keyboard`, `capturescreenshot`, `customizeuistyle`, `customizeappearancesettings`, `getlockstate` and `getdisplayinfo`.
  - It lacks `remote.hid.digitizer`, `remote.hid.tvremote`, `remote.devicecontrol.orientation` and `pasteboard`, though its image lists `tvremote` and `digitizer`.
  - `devicectl device info voiceover` fails with CoreDeviceError 21062, "VoiceOver is not supported on this device".
- **Through `devicectl`, warm:**
  - `capture screenshot` returned a 3840 × 2160 PNG in 6.9 s.
  - `info displays` reads `TVOut` at 3840 × 2160 and point scale 1. Its `backlightState` was `off` on the display and `activeOn` at the top level, with the TV showing.
  - `info lockState` reads `passcodeRequired` and `unlockedSinceBoot`.
  - `info appearance` reads `userInterfaceStyle`, `textSize` and `increaseContrast`.
- **Unchanged drivers through a link layer.** A second spike put a `GuestLink` protocol under `GuestConnection`, with a simulator link for `xpc_connection_t` and a remote one for the RemoteXPC functions. `GuestButtons`, `GuestKeyboard` and `GuestSettingActions` then ran on the device unchanged.
  - **Keyboard.** Opening the keyboard took 3.1–3.5 s, binding resolution included. The keyboard's `return` chose a profile, and typing `test` into Search, then four deletes, worked.
  - **Buttons.** `select` opened Search from the Home screen, but did nothing on the profile picker shown after waking, where `return` worked (cause unknown).
  - **Setting actions.**
    - The message's `CoreDevice.deviceIdentifier` must be the device's CoreDevice identifier. The hardware UDID gets CoreDevice error 0 with no description.
    - `GetUserInterfaceStyle` (`{"style":"light"}`) took 1.0 s cold. `GetDeviceTextSize` (`{"textSize":{"size":{"large":{}}}}`) and `GetDeviceIncreaseContrast` each took 90–180 ms warm.
    - On tvOS, Reduce Motion fails with 21040 and Reduce Transparency with 21041, both "not supported on this device". Liquid Glass has no service.
  - **Screenshots.**
    - `CaptureScreenshotActionDeclaration` takes the top-level `CaptureScreenshotInput` (`displayUniqueID`, `requestedFormat` `"png"`) and returns `CaptureScreenshotOutput`, whose `image` is a `CGImage` (base64 PNG as JSON).
    - With the display lit, a 3840 × 2160 capture took 4.5–4.9 s through the spike's JSON round trip.
    - While the Apple TV sleeps (top-level `backlightState` `off`), it fails with 25005, "Display reports zero-sized native size", through `devicectl` too.
    - A `menu` press woke the Apple TV, onto its profile picker.
- **iPhone 15 Pro, iOS 27.2.1 (24B156), wired, no passcode.**
  - **Features.** It lists every feature simdrive uses: `remote.hid.digitizer`, `remote.hid.button`, `remote.hid.keyboard`, `remote.universalhidservice`, `remote.devicecontrol.orientation`, `pasteboard`, `capturescreenshot`, `customizeuistyle`, `customizeappearancesettings`, `customizeliquidglass`, `voiceover`, `getlockstate` and `getdisplayinfo`.
  - **Touch.** The unchanged `GuestTouchscreen` with `DigitizerTarget.mainScreen` and native unit coordinates worked. Swipes paged the Home screen both ways in 0.4 s, and a tap opened Clock in 74 ms. A drag from (0.5, 0.999) with the `bottom` edge went home. Opening the touchscreen took 0.3 s.
  - **Orientation.** The unchanged `GuestOrientation` read in 5–8 ms and set `landscapeLeft`, then `portrait`, in 5–9 ms.
    - The set is a simulated physical orientation, and it persists. Afterwards the device reported `portrait` instead of the `faceUp` its sensor had given.
    - With Safari in front, `landscapeLeft` turned its interface. `devicectl`'s screenshot came back upright at 2556 × 1179, with the Dynamic Island on the left, so screenshots follow the interface, as on simulators. Back in `portrait`, the bottom-edge home swipe did nothing while a system alert ("iPhone Storage Full") was up.
    - `devicectl device orientation set` also takes `faceUp` and `faceDown`, which restored the reading. CoreDevice has no call to clear the override, so whether the sensor takes over again is unverified.
  - **Setting actions.** All took 50–100 ms warm and 1.3 s cold: `GetUserInterfaceStyle`, `GetDeviceTextSize`, `GetReduceMotion`, `GetReduceTransparency`, `GetDeviceIncreaseContrast`, `GetLiquidGlassConfiguration` and `GetVoiceOver`.
  - **Screenshots.** `CaptureScreenshotActionDeclaration` returned a 1179 × 2556 PNG in 1.1–1.2 s. `devicectl device info displays` lists the panel (`LCD`, 1179 × 2556, point scale 3) and a second display whose backlight was off.
  - **Pasteboard.** Not read, since this was the owner's own phone.
- **Not tried:**
  - pinch and rotate
  - hardware buttons and the keyboard on an iPhone
  - the pasteboard
  - decoding the `CGImage` directly instead of through JSON
  - the simulator matrix on the link-layer change

## Finding more

- **Swift symbols**: `nm -gU <binary> | swift demangle`, filtered for the type or feature. ABIBridge takes the demangled names.
- **Objective-C selectors**: CoreSimulator's methods are not in `nm`'s exports. `dlopen` the framework and list classes and methods through the Objective-C runtime (`objc_copyClassList`, `class_copyMethodList`, `method_getTypeEncoding` for argument types).
- **Notification names**: `strings` on UIKit and libAccessibility, matched against the setting's key.
- **Preference keys**: diff `simctl spawn <udid> defaults export <domain> -` before and after toggling in Settings.
- **CoreDevice features**: `RemoteDevice.supportsFeature(identifiedBy:)` against identifiers from CoreDevice's strings.
- **Prior art**: NeoSimulator for CoreDevice and guest HID, idb for AXPTranslator.

## SimulatorKit (unused)

`IndigoHIDMessageForKeyboardArbitrary` and `SimDeviceLegacyHIDClient` still exist in Xcode 27's SimulatorKit. Messages send without error but never reach apps. NeoSimulator uses `IndigoHIDMessageForTrackpadMoveEvent` for Apple TV Remote touch-surface swipes, a possible follow-up.
