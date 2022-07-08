//
//  AppInformationView.swift
//  LivePhotosCleanUp
//
//  Created by Marco Schillinger on 15.01.21.
//

import SwiftUI
import Photos
import os.log

struct AppSettingsView: View {

    @EnvironmentObject var model: SettingsModel
    @State private var showLibraryPicker = false
    @Binding var isSheetVisible: Bool
    @State private var showLimitPicker: Bool = false
    @State private var selectedPhotoLimit: Int = UserDefaults.standard.integer(forKey: Constants.photoLimit)

    fileprivate func openSettingsForApp() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, completionHandler: { (success) in
            Logger.init().info("Settings opened: \(success)")
        })
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("view_appSettings_info_section_header")) {
                    Text(NSLocalizedString(model.accessLevelDescription, comment: ""))
                    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
                    case .notDetermined, .authorized, .restricted:
                        EmptyView()
                    case .denied:
                        Button(action: { openSettingsForApp() },
                               label: { Text("view_appSettings_photoAccess_openSettings") })
                    case .limited:
                        Button(action: { showLibraryPicker.toggle() },
                               label: { Text("view_appSettings_photoAccess_adjustSelection") })
                        Button(action: { openSettingsForApp() },
                               label: { Text("view_appSettings_photoAccess_openSettings") })
                        Text("view_appSettings_photoAccess_adjustSelection_warning")
                    @unknown default:
                        EmptyView()
                    }
                }
                Section(header: Text("view_appSettings_settings_section_header")) {
                    HStack {
                        Text("view_appSettings_settings_limit")
                        Spacer()
                        Text("\(selectedPhotoLimit)")
                    }.onTapGesture {
                        showLimitPicker.toggle()
                    }

                    if showLimitPicker {
                        Picker(selection: $selectedPhotoLimit, label: Text("\(selectedPhotoLimit)")) {
                            ForEach(Array(stride(from: 10, to: 501, by: 10)), id: \.self) { number in
                                Text("\(number)")
                            }
                        }
                        .onTapGesture {
                            showLimitPicker.toggle()
                        }
                        .pickerStyle(.wheel)
                    }

                    Toggle("view_appSettings_settings_delete", isOn: $model.deleteOriginalPhotos)
                    Toggle("view_appSettings_settings_addToAlbum", isOn: $model.moveToAlbum)
                    Toggle("view_appSettings_settings_loadICloud", isOn: $model.includeIcloudPhotos)
                    Button("view_appSettings_resetDuplicated") {
                        model.resetDuplicatedInformation()
                    }
                }
                Section(footer:
                            Text("view_appSettings_appInfo_footer_version") + Text(" \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                ) {
                    NavigationLink(destination: ImprintAndPrivacy()) {
                        Text("view_appSettings_appInfo_imprint")
                    }
                }
            }
            .navigationBarTitle("view_appSettings_navigation_title", displayMode: .inline)
            .navigationBarItems(trailing: Button("view_appSettings_done") {
                model.photoLimit = selectedPhotoLimit
                isSheetVisible = false
            })
            .background(Group {
                if showLibraryPicker {
                    LimitedLibraryPicker(isPresented: $showLibraryPicker)
                }
            })
        }
    }
}

struct AppInformationView_Previews: PreviewProvider {
    static var previews: some View {
        AppSettingsView(isSheetVisible: .constant(true))
            .preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 12"))
            .previewDisplayName("iPhone 12 dark")
        AppSettingsView(isSheetVisible: .constant(true))
            .preferredColorScheme(.light)
            .previewDevice(PreviewDevice(rawValue: "iPhone 12"))
            .previewDisplayName("iPhone 12 light")
    }
}

