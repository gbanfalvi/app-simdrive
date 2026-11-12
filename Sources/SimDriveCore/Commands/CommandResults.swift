import SimDriveNative

// The JSON results of commands, as the README's JSON results describe them.

extension AccessibilityApplication {
    var json: JSONValue {
        ["name": JSONValue(name), "pid": JSONValue(pid.map(Int.init))]
    }
}

extension GuestOrientationReading {
    /// `physical` keeps a raw value that names no orientation, such as face-up.
    var json: JSONValue {
        ["orientation": JSONValue(orientation?.name), "physical": .string(DeviceOrientation(rawValue: physical)?.name ?? physical)]
    }
}

extension Hinge {
    var json: JSONValue {
        ["angle": JSONValue(angle), "posture": JSONValue(posture?.rawValue)]
    }
}

extension PasteboardItem {
    var json: JSONValue {
        ["types": .array(types.map(JSONValue.string)), "text": JSONValue(text)]
    }
}

extension Screenshot {
    func json(display: SimulatorDisplay?, orientation: DeviceOrientation?) -> JSONValue {
        ["path": .string(path), "width": JSONValue(image.width), "height": JSONValue(image.height),
         "fullPath": .string(fullPath), "fullWidth": JSONValue(full.width), "fullHeight": JSONValue(full.height),
         "display": JSONValue(display?.index), "orientation": JSONValue(orientation?.name)]
    }
}

extension SimulatorDisplay {
    var json: JSONValue {
        ["index": JSONValue(index), "name": .string(name), "role": .string(role),
         "width": JSONValue(nativeSize.width), "height": JSONValue(nativeSize.height)]
    }
}
