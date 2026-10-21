//
//  SecretaryApp.swift
//  secretary
//
//  Created by Davey Adams on 10/21/26.
//

import SwiftUI

@main
struct SecretaryApp: App {

    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "person.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
