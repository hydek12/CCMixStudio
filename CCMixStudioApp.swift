//
//  CCMixStudioApp.swift
//  CCMixStudio
//
//  Created by Tim Sanvido on 11/20/26.
//

import Darwin
import SwiftUI

@main
enum CCMixStudioEntrypoint {
    static func main() {
        let arguments = CommandLine.arguments
        if MixCLI.shouldRunCLI(arguments: arguments) {
            let exitCode = MixCLI.run(arguments: Array(arguments.dropFirst()))
            Darwin.exit(exitCode)
        }

        AppLaunchConfiguration.shared = MixCLI.parseGUILaunchConfiguration(arguments: arguments)
        CCMixStudioApp.main()
    }
}

struct CCMixStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
