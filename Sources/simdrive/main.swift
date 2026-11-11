import Foundation
import SimDriveCore

exit(await SimDriveCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
