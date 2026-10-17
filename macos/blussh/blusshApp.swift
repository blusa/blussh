//
//  blusshApp.swift
//  blussh
//
//  Created by Pablo Pusiol on 8/4/25.
//

import SwiftUI

@main
struct blusshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
