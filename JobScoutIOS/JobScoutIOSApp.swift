//
//  JobScoutIOSApp.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import SwiftUI

@main
struct JobScoutIOSApp: App {
    @State private var store = MobileJobStore()

    var body: some Scene {
        WindowGroup {
            MobileVacanciesView(store: store)
        }
    }
}
