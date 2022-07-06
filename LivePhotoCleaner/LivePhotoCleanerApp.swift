//
//  LivePhotosCleanUpApp.swift
//  LivePhotosCleanUp
//
//  Created by Denise Fritsch on 29.09.20.
//

import SwiftUI
import Firebase

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

@main
struct LivePhotoCleanerApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
            // this could be read from a plist file as well, there should be no difference in functionality
            // as we've got our Keys enum we set the defaults here to make sure we do not have different string values
        UserDefaults.standard.register(defaults: [
            Constants.includeIcloudImages: false,
            Constants.deleteLivePhotos: true,
            Constants.moveToAlbum: true,
            Constants.photoLimit: 250,
        ])
    }

    var body: some Scene {
        WindowGroup {
            PhotoOverview()
                .environmentObject(SettingsModel())
        }
    }
}
