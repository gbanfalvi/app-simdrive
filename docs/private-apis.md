# Private APIs

What simdrive calls, and what was learned about it, on Xcode 27.0 and 27.2. Names are as resolved at run time; any may change with an Xcode update. `doctor` exercises most of them.

## CoreSimulator

Loaded from `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`.

- `SimServiceContext +sharedServiceContextForDeveloperDir:error:`, then `-defaultDeviceSetWithError:`, then `devicesByUDID` (`[UUID: SimDevice]`). One context per developer directory.
- `SimDevice` getters: `name`, `stateString` (`Booted`), `runtimeIdentifier` (`com.apple.CoreSimulator.SimRuntime.iOS-18-3`), `deviceTypeIdentifier`, `lastBootedAt`.
- `-lookup:error:` returns a caller-owned Mach send right to a guest service, or 0 or `UInt32.max` when there is none. Probing for a service means looking it up and deallocating the right.
- `-postDarwinNotification:error:` posts in the guest, as `notifyutil -p` there would.
- `-sendAccessibilityRequestAsync:completionQueue:completionHandler:` carries AXPTranslator's requests to the guest.

### Interface orientation

- Chain: `SimDevice.io`, its `ioPorts`, the port whose `portIdentifier` is `com.apple.framebuffer.server`, its `descriptor` (a `SimScreenAdapter`), then `-enumerateScreensWithCompletionQueue:completionHandler:`. Each screen's `screenProperties` (`SimScreenProperties`) has `screenID` and `uiOrientation`, both `UInt32`. A round trip takes milliseconds.
- The ports are ROCK remote proxies. `value(forKey:)` fails on them; `perform(_:)`, and `method(for:)` cast to a C function for scalars, work.
- `uiOrientation`, as `simctl io enumerate` labels it: 0 Ambiguous, 1 Portrait, 2 Portrait Upside Down, 3 Landscape Left, 4 Landscape Right. The names are UIKit's interface orientations, but the numbers are not `UIInterfaceOrientation`'s, which swaps 3 and 4.
- Observed: device `landscape-left` gives 4, `landscape-right` gives 3, since the interface counter-rotates the device. 2 was never observed.
- `screenID` equals the `simctl` display index. A single-display device's screen is 1.

### Screenshots

`simctl io <udid> screenshot --type=png [--display=N] <path>`. A multi-display device refuses without `--display` and lists its panels as `--display=N <name> (<role>) <width>x<height>`; simdrive parses that listing to find them. The Duo's cover panel has the role `primary`, the inner panel `primary-1`.

## Guest services

- A Mach send right from `lookup:error:` becomes an XPC connection through `xpc_endpoint_create_mach_port_4sim` and `xpc_connection_enable_sim2host_4sim`, resolved with ABIBridge from libxpc. A created endpoint owns the right.
- libxpc requires a connection to be activated before its release, even one being discarded.
- Messages are XPC dictionaries with the feature identifier, a message type and a payload, under field names read from `CoreDeviceUtilities.HIDXPCServiceEvent`'s static getters. Payloads are CoreDeviceUtilities values encoded with `Mercury.XPCObjectEncoder`; replies decode with `Mercury.XPCObjectDecoder`, and an error field holds an `NSErrorContainer`.
- The guest removes the services a connection created when the connection ends, and drops events it had not yet activated. Cancelling a connection also discards unsent messages, so simdrive waits on a barrier after each input.
- The guest matches a new service shortly after it appears and drops events sent before; simdrive waits 400 ms. Ending a connection within 500 ms of its last event lost that event on the Duo; simdrive waits 1000 ms.

| Feature (`com.apple.coredevice.feature.` …) | Message type | Payload |
| --- | --- | --- |
| `remote.universalhidservice` | `Request` | `DDIUniversalHIDServicePayload.Request`: `createService(HIDServiceDescriptor)`, `send(Data, HIDServiceID)`, `removeService(HIDServiceID)` |
| `remote.hid.digitizer` | `IndigoDigitizerEvent` | `IndigoDigitizerEvent(pointOne:pointTwo:eventType:edge:target:)` |
| `remote.hid.button` | `IndigoButtonEvent` | `IndigoButtonEvent(usagePage:usageCode:state:)` |
| `remote.devicecontrol.orientation` | `OrientationRequest` | `currentOrientation` or `changeOrientation(DeviceOrientation)`; the reply is `OrientationInfo` |

### Keyboard

- The service comes from `CoreDevice.HIDServiceDescriptor.mainKeyboard()`, passed through `setSoftwareKeyboard(false)`: the guest takes input only from a hardware keyboard, which the main keyboard is not by default.
- Reports come from `UniversalHIDKit.EventObserver<NSEvent>` (`init(eventMask:)`, `processEvent(_:)`), as DeviceHub makes them. Its results are `(HIDReport, senderID)` pairs.
- Two `UniversalHID` modules exist: the system's, which UniversalHIDKit uses, and a copy bundled in `CoreDevice.framework/Versions/A/Frameworks`, whose `HIDReport` CoreDevice's services take. Their types are distinct, so reports cross as `Data`.
- The observer reads a key from its key code alone, and keeps modifier state per observer, so each keyboard needs its own.

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

- Present only when the hardware model is `v68`, `v68ap` or `v68dev` (the iPhone Duo) and the device supports `remote.hid.vendordefined`, `monitormotion` and `remote.universalhidservice`, and `motionManager().supportsHingeAngle` is true.
- Reading: `MonitorMotionProtocol.motionManager().monitorHingeAngle(config: HingeAngleStreamConfig(changeThreshold:updateInterval:))` returns an `AsyncThrowingStream<[DeviceHingeAngleSnapshot], Error>`; each snapshot has `isAngleValid` and `angle` (`Measurement<UnitAngle>`). The returned owner must stay alive while the stream is read.
- Setting: `HIDVendorDefined.send(usagePage: 0xFF61, usage: 0x5B, version: 0, data:)`, where `data` is an `IOCFSerialize` binary dictionary: `provider` `com.apple.Virtualization.VirtualMachines`, `source` `hinge-slider-control`, `type` `range`, `value` the angle in degrees.
- The hinge animates toward the angle and settles near it. simdrive sends 0, 130 and 180 and reads below 15° as closed and above 175° as open.
- No other path was found: `simctl`, `devicectl`, DeviceHub's strings, XCUITest and NeoSimulator's URL scheme (which only has `open-device`) have no hinge control.

### Pasteboard

- `PasteboardCapability` (`com.apple.coredevice.feature.pasteboard`): `currentPasteboardSnapshot(pasteboardName: "general", dataPolicy:)` and `setPasteboardContents(pasteboardName:pasteboardSnapshot:)`, as `devicectl device pasteboard` uses them.
- `PasteboardSnapshot(from: NSPasteboard, dataPolicy:)` and `write(to: NSPasteboard)` convert. `PasteboardDataInclusionPolicy.allResolved` includes every type's data, so neither side keeps promises the other must resolve.
- Swift initializers called through ABIBridge consume their arguments, so each capture needs its own copy of the policy, as each `EventObserver(eventMask:)` needs its own mask.

## AccessibilityPlatformTranslation

Loaded from `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework`.

- `AXPTranslator.sharedInstance`, with `supportsDelegateTokens`, `accessibilityEnabled` and `bridgeTokenDelegate` set. The delegate must conform to `AXPTranslationTokenDelegateHelper`, which has no header, so simdrive adds it with `class_addProtocol`. The translator holds the delegate weakly.
- The delegate implements `accessibilityTranslationDelegateBridgeCallbackWithToken:`, returning a block that sends a request through `SimDevice` and waits for the reply; `accessibilityTranslationConvertPlatformFrameToSystem:withToken:`, which returns frames unchanged so they stay in guest points; and `accessibilityTranslationRootParentWithToken:`, returning nil.
- The token is the UDID, set on every translation object with `bridgeDelegateToken` before converting it with `macPlatformElementFromTranslation:`.
- `frontmostApplicationWithDisplayId:bridgeDelegateToken:` answers for the frontmost app whatever display ID it gets. Its translation's `pid` is the app's process; the element's label is its name, a single space for SpringBoard.
- `objectAtPoint:displayId:bridgeDelegateToken:` hit-tests in points of the panel's native orientation; the display ID is the `simctl` index, 0 on single-display devices.
- The frontmost element's frame size is the app's screen size in points. It turns with the interface on some devices and not on others.
- The translator blocks while the guest answers, so it runs on its own queue.

### The snapshot attribute

- `_accessibilityProcessAttribute:parameter:` with `AXTestingSnapshotParameterizedAttribute` returns an element's subtree. Parameters: `attributes` (XCUITest's attribute numbers), `maxDepth`, `maxChildren`, `maxArrayCount`, `traverseFromParentsToChildren`.
- Numbers in use: label 2001, hint 2002, frame 2003, traits 2004, value 2006, activation point 2007, language 2008, is-accessibility-element 2016, URL 2020, custom actions 2036, has-focus 2094, expanded status 2114, heading level 2180, input labels 2186, container type 2187, class name 5003, minimum 5005, maximum 5006, numeric value 5011, identifier 5019, view controller class 5042, placeholder 5043, automation type 5058.
- Others can crash the app or return whole subtrees. Visibility (2025) hit-tests every node and times out on large screens.
- Traits are `UIAccessibilityTraits` bits plus private ones, such as bit 33 on static text inside cells; simdrive keeps the public bits.
- Custom content is not in snapshots. Each element's `AXCustomContent` attribute returns it archived, unarchived as `[AXCustomContent]`.

## Guest preferences

- `simctl spawn <udid> defaults export <domain> -` prints a property list; `defaults write <domain> <key> -int|-float|-string <value>` writes.
- Accessibility keys live in `com.apple.Accessibility`; the Liquid Glass tint is `UIViewGlassTintAmount` in `com.apple.UIKit`, a 32-bit float that defaults to 0.5 while unset, announced by `UIViewGlassTintAmountUpdateNotification`.
- Accessibility notifications are `com.apple.accessibility.<name>`; most have a `com.apple.accessibility.cache.<name>` counterpart. The pairs are in [`SettingCatalog.swift`](../Sources/SimDriveCore/Settings/SettingCatalog.swift); [AGENTS.md](../AGENTS.md) describes how to find new ones.

## Finding more

- **Swift symbols**: `nm -gU <binary> | swift demangle`, filtered for the type or feature. ABIBridge takes the demangled names.
- **Objective-C selectors**: CoreSimulator's methods are not in `nm`'s exports. `dlopen` the framework and list classes and methods through the Objective-C runtime (`objc_copyClassList`, `class_copyMethodList`, `method_getTypeEncoding` for argument types).
- **Notification names**: `strings` on UIKit and libAccessibility, matched against the setting's key.
- **Preference keys**: diff `simctl spawn <udid> defaults export <domain> -` before and after toggling in Settings.
- **CoreDevice features**: `RemoteDevice.supportsFeature(identifiedBy:)` against identifiers from CoreDevice's strings.
- **Prior art**: NeoSimulator for CoreDevice and guest HID, idb for AXPTranslator.

## SimulatorKit (unused)

`IndigoHIDMessageForKeyboardArbitrary` and `SimDeviceLegacyHIDClient` still exist in Xcode 27's SimulatorKit. Messages send without error but never reach apps. NeoSimulator uses `IndigoHIDMessageForTrackpadMoveEvent` for Apple TV Remote touch-surface swipes, a possible follow-up.
