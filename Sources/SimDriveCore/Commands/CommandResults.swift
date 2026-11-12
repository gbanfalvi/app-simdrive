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

extension CrashSummary {
    var json: JSONValue {
        ["process": .string(process), "pid": JSONValue(pid), "time": .string(time), "exception": .string(exception),
         "reason": JSONValue(reason), "frames": .array(frames.map(JSONValue.string)), "path": .string(path)]
    }
}

extension LogDigest.Entry {
    /// Leaves out the default level, a single repeat and the fields the read filtered on.
    var json: JSONValue {
        var fields: [String: JSONValue] = ["ms": JSONValue(milliseconds), "message": .string(message)]
        if level != .default { fields["level"] = .string(level.name) }
        if let process { fields["process"] = .string(process) }
        if let subsystem { fields["subsystem"] = .string(subsystem) }
        if let category { fields["category"] = .string(category) }
        if repeats > 1 { fields["repeats"] = JSONValue(repeats) }
        return .object(fields)
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
