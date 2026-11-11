# Third-party code

## NeoSimulator

`Sources/SimDriveNative` adapts code from [NeoSimulator](https://github.com/lynnswap/NeoSimulator) at commit `1dfc4af`:

| simdrive | NeoSimulator |
| --- | --- |
| `Simulator/SimulatorDevice.swift`, `SimulatorGuest.swift`, `GuestMessageCodec.swift` | `NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift` |
| `DeviceControl/GuestOrientation.swift` | `NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift`, `DeviceOrientation.swift` |
| `Input/GuestHIDService.swift` | `NeoSimulatorDeviceIO/CoreDevice/CoreDeviceHIDService.swift` |
| `Input/KeyboardBindings.swift`, `GuestKeyboard.swift` | `NeoSimulatorPresentationAdapters/Native/CoreDeviceHIDReports.swift`, `NativeDeviceKeyboard.swift` |
| `Input/GuestTouchscreen.swift`, `GuestButtons.swift` | `NeoSimulatorPresentationAdapters/Native/GuestScreenInput.swift` |
| `CoreDevice/CoreDeviceRemote.swift` | `NeoSimulatorDeviceIO/CoreDevice/CoreDeviceRemoteScreenDevice.swift` |
| `DeviceControl/CoreDeviceHinge.swift` | `NeoSimulatorPresentationAdapters/Native/NativeDevicePostureTransport.swift`, `NeoSimulatorKit/Devices/DevicePosture.swift` |
| `DeviceControl/CoreDevicePasteboard.swift` | `NeoSimulatorPresentationAdapters/Native/CoreDevicePasteboard.swift` |
| `Support/NativeFrameworks.swift` | `NeoSimulatorNative/NativeFrameworks.swift` |

```
MIT License

Copyright (c) 2026 Kazuki Nakashima

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ABIBridge

Linked as a Swift package dependency: [lynnswap/ABIBridge](https://github.com/lynnswap/ABIBridge) 0.19.1, under its own license.
