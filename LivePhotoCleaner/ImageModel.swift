//
//  ImageModel.swift
//  LivePhotosCleanUp
//
//  Created by Marco Schillinger on 11.01.21.
//

import UIKit
import SwiftUI
import Photos
import os.log
import Firebase

class ImageModel: NSObject, ObservableObject {

    var logger = Logger()

    var didShowiCloudAlertError = false

    var duplicatedAssets = Set<String>()

    @AppStorage(Constants.photoLimit) var maxImageSelectionCount = 250

    @Published var approxFreedSpace = 0.0
    @Published var images = [CustomImage]()
    @Published var editedImages = [CustomImage]()
    @Published var selectedImages = [CustomImage]()
    @Published var selectedEditedItemsCount = 0
    @Published var selectedNormalItemsCount = 0

    @Published var alert: AlertItem?

    var fetchResults: PHFetchResult<PHAsset>?

    var imageIndexInformation = [String: (imagesIndex: Int?, editedImagesIndex: Int?, selectedImagesIndex: Int?)]()
    var allAssets = [String: PHAsset]()

    private var activeRequests = Set<PHImageRequestID>()
    private var fetchAllowed = true

    private var duplicator: PhotoDuplicator

    override init() {
        duplicator = PhotoDuplicator()
        super.init()

        NotificationCenter.default.addObserver(forName: Notification.Name("duplicatedImagesReset"), object: nil, queue: nil, using: duplicationListDeletedHandler)


        duplicator.setCallbackHandlers(completionHandler: self.handleDuplicationCompletion,
                                       progressHandler: self.handleDuplicationProgress,
                                       alerthandler: self.handleDuplicationAlert)

        PHPhotoLibrary.shared().register(self)

        readAlreadyDuplicatedImages()
        fetchAllPhotos()
    }

    func duplicationListDeletedHandler(_ notification: Notification) {
        let assetIds = Array(duplicatedAssets)
        duplicatedAssets.removeAll()

        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        allPhotosOptions.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            PHAssetMediaSubtype.photoLive.rawValue
        )

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: allPhotosOptions)
        var assets = [PHAsset]()

        fetched.enumerateObjects { (asset, index, stop) in
            assets.append(asset)
        }

        loadAndAddAssets(assets: assets)
    }

    // MARK: - Public part
    // MARK: Selection
    // unmodified images
    func selectAllImages() {
        selectAllImages(of: &images)
    }

    func deselectAllImages() {
        deselectAllImages(of: &images)
    }

    // edited images
    func selectAllEditedImages() {
        selectAllImages(of: &editedImages)
        selectedEditedItemsCount = editedImages.count
    }

    func deselectAllEditedImages() {
        deselectAllImages(of: &editedImages)
        selectedEditedItemsCount = 0
    }

    // specific images
    private func deselectAllImages(of list: inout [CustomImage]) {
        let editedIDs = list.map{ $0.id }
        selectedImages = selectedImages.filter{ !editedIDs.contains($0.id) }
        for index in list.indices {
            list[index].selected = false
        }
        selectedNormalItemsCount = 0
        selectedEditedItemsCount = 0
    }

    private func selectAllImages(of list: inout [CustomImage]) {
        var imageSum = selectedNormalItemsCount + selectedEditedItemsCount
        for index in list.indices {
            if maxImageSelectionCount-1 > 0 && imageSum > maxImageSelectionCount-1 {
                self.alert = AlertItem(title: "Photo Limit erreicht",
                                       message: NSLocalizedString("Das eingestellte Foto Limit von \(maxImageSelectionCount) wurde erreicht.", comment: ""),
                                       dismissOnly: true,
                                       dismissButton: ("Ok", { self.alert = nil }))
                break
            }
            selectedImages.append(list[index])

            // bool for should be cleared
            selectedImages[index].selected = false
            // bool for is selected
            list[index].selected = true
            imageSum += 1
        }
        calculateFreedSpace(selectAll: true)
    }

    // image tap actions
    func imageTapped(id: String) { // could be refactored to not always search both lists
        image(with: id, tappedIn: &editedImages, edited: true)
        image(with: id, tappedIn: &images, edited: false)
        calculateFreedSpace()
    }

    // MARK: - private

    private func readAlreadyDuplicatedImages() {
        guard var documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // log
            return
        }

        documentsDirectory.appendPathComponent(Constants.imageFileName)

        if !FileManager.default.fileExists(atPath: documentsDirectory.path) {
            FileManager.default.createFile(atPath: documentsDirectory.path, contents: nil, attributes: nil)
        }

        if let fileHandler = try? FileHandle(forUpdating: documentsDirectory.absoluteURL), let data = try? fileHandler.readToEnd() {
            let assetString = String(data: data, encoding: .utf8)
            if let ids = assetString?.components(separatedBy: "\n") {
                duplicatedAssets.formUnion(ids)
            }
            fileHandler.closeFile()
        }
    }

    private func image(with id: String, tappedIn images: inout [CustomImage], edited: Bool) {
        if let index = images.firstIndex(where: { $0.id == id }) {
            if images[index].selected {
                selectedImages.removeAll(where: { $0.id == id })
                if edited {
                    selectedEditedItemsCount -= 1
                } else {
                    selectedNormalItemsCount -= 1
                }
            } else {
                selectedImages.append(images[index])
                if edited {
                    selectedEditedItemsCount += 1
                } else {
                    selectedNormalItemsCount += 1
                }
            }
            let imageSum = selectedNormalItemsCount + selectedEditedItemsCount
            if imageSum > maxImageSelectionCount {
                self.alert = AlertItem(title: "Photo Limit erreicht",
                                       message: NSLocalizedString("Das eingestellte Foto Limit von \(maxImageSelectionCount) wurde erreicht.", comment: ""),
                                       dismissOnly: true,
                                       dismissButton: ("Ok", {self.alert = nil}))
            } else {
                images[index].selected.toggle()
            }
        }
    }

    // reset
    private func reset() {
        DispatchQueue.main.async {
            for index in self.images.indices {
                self.images[index].selected = false
            }
            for index in self.editedImages.indices {
                self.editedImages[index].selected = false
            }
            self.selectedEditedItemsCount = 0
            self.selectedImages.removeAll()
        }
    }



    // MARK: get assets
    /// Tries to fetch all photos that are on the device and in cloud.
    /// The fetched images are added to the arrays async.
    private func fetchAllPhotos() {
        allAssets.removeAll()
        self.logger.info("FetchAll started")
        fetchAllowed = true
        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        allPhotosOptions.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            PHAssetMediaSubtype.photoLive.rawValue
        )
        fetchResults = PHAsset.fetchAssets(with: allPhotosOptions)

        guard let fetchResults = self.fetchResults else {
            logger.error("Image fetch failed")
            return
        }

        var assets = [PHAsset]()
        var assetIds = Set<String>()
        fetchResults.enumerateObjects { (asset, index, stop) in
            if !self.duplicatedAssets.contains(asset.localIdentifier) {
                assets.append(asset)
                assetIds.insert(asset.localIdentifier)
            }
        }

        // we could remove images from the "already deleted images" list here - using a set of all ids and the already duplicated ids
        // images that are duoplicated but not in all ids can be removed form the list

        // we could easily calculate this if we'd use sets
        DispatchQueue.main.async {
            self.images.removeAll(where: { !assetIds.contains($0.id) })
            self.editedImages.removeAll(where: { !assetIds.contains($0.id) })
            self.selectedImages.removeAll(where: { !assetIds.contains($0.id) })
        }

        loadAndAddAssets(assets: assets)

        self.logger.info("FetchAll finished")
    }

    fileprivate func loadAndAddAssets(assets: [PHAsset]) {
        let allowIcloudImages = UserDefaults.standard.bool(forKey: Constants.includeIcloudImages)
        logger.info("Network access allowed to download photos: \(allowIcloudImages)")

        let manager = PHImageManager.default()
        let option = PHImageRequestOptions()
        option.isNetworkAccessAllowed = allowIcloudImages
        if allowIcloudImages {
            logger.info("Adding progress handler for icloud images")
            option.progressHandler = handleCloudDownloadProgress
        }

        for index in 0..<assets.count {
            if !fetchAllowed { break }
            let identifier = assets[index].localIdentifier
            self.logger.log("\(identifier)")

            allAssets[identifier] = assets[index]

            let requestId = requestImage(manager, assets[index], option, allowIcloudImages)
            logger.info("adding id \(requestId)")
            activeRequests.insert(requestId)
        }

    }

    fileprivate func getAssetsOfSelectedImages() -> [PHAsset] {
        var assetsToDelete: [PHAsset] = [PHAsset]()

        self.selectedImages.forEach { image in
            if let asset = allAssets[image.id] {
                assetsToDelete.append(asset)
            }
        }
        return assetsToDelete
    }

    // MARK: Delete
    private func deleteApproved() {
        self.logger.log("Delete approved")
        let assetsToDelete: [PHAsset] = getAssetsOfSelectedImages()

        DispatchQueue.global(qos: .userInitiated).async {
            if UserDefaults.standard.bool(forKey: Constants.moveToAlbum) {
                self.createLPCAlbumIfNotPresent()
            }

            self.duplicator.setAssets(assets: assetsToDelete)
            self.duplicator.startDuplication()
        }
    }

    func deleteSelectedLivePhotos() {
        if selectedEditedItemsCount == 0 {
            deleteApproved()
        } else {
            alert = AlertItem(title: "view_selectedPhotoOverview_alert_warning_title",
                              message: String(format: NSLocalizedString("view_selectedPhotoOverview_alert_warning_message", comment: ""), selectedEditedItemsCount),
                              dismissOnly: false,
                              primaryButton: ("view_selectedPhotoOverview_alert_cancel_button", action: {}),
                              secondaryButton: ("view_selectedPhotoOverview_alert_continue_button", action: deleteApproved))
        }
    }

    // MARK: - Private helper methods

    fileprivate func createAndAddImage(_ asset: PHAsset, _ res: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            //        self.logger.debug("adding asset \(asset.localIdentifier)")
            let isEdited = PHAssetResource.assetResources(for: asset).contains(where: { $0.type == .adjustmentData } )

            if let tupleForImage = self.imageIndexInformation[asset.localIdentifier] {
                if let editedIndex = tupleForImage.editedImagesIndex {
                    DispatchQueue.main.async {
                        Crashlytics.crashlytics().log("updating edited image")
                        self.editedImages[editedIndex].image = res
                    }
                }
                if let imagesIndex = tupleForImage.imagesIndex {
                    DispatchQueue.main.async {
                        Crashlytics.crashlytics().log("updating normal image")
                        self.images[imagesIndex].image = res
                    }
                }
                if let selectedImagesIndex = tupleForImage.selectedImagesIndex {
                    DispatchQueue.main.async {
                        Crashlytics.crashlytics().log("updating selected image")
                        self.selectedImages[selectedImagesIndex].image = res
                    }
                }
            } else {
                let image = CustomImage(id: asset.localIdentifier, image: res)
                if isEdited {
                    DispatchQueue.main.async {
                        Crashlytics.crashlytics().log("adding new edited image")
                        self.editedImages.append(image)
                        self.imageIndexInformation[asset.localIdentifier] = (nil, self.editedImages.count - 1, nil)
                    }
                } else {
                    DispatchQueue.main.async {
                        Crashlytics.crashlytics().log("adding new normal image")
                        self.images.append(image)
                        self.imageIndexInformation[asset.localIdentifier] = (self.images.count - 1, nil, nil)
                    }
                }
            }
            //        self.logger.debug("adding asset \(asset.localIdentifier) finished at")
        }
    }

    fileprivate func requestImage(_ manager: PHImageManager, _ asset: PHAsset, _ option: PHImageRequestOptions, _ allowIcloudImages: Bool) -> PHImageRequestID {
        manager.requestImage(for: asset,
                                targetSize: CGSize(width: Constants.maxImageWidth, height: Constants.maxImageHeight),
                                contentMode: .aspectFit,
                                options: option,
                                resultHandler: { (result, info) -> Void in
            if let inf = info, let key = inf[PHImageResultIsInCloudKey] as? Bool {
                self.logger.info("Image is cloud image: \(key)")

                if !self.images.contains(where: { $0.id == asset.localIdentifier }) {
                    // maybe replace this image with the placeholder only in case it is not yet in any list
                    // it seems as if the placeholder is in general present, but the image is not loaded correctly. so we add this image only if there is none yet.
                    // this might result in no high-res image, so another rework might be needed
                    self.createAndAddImage(asset, UIImage(systemName: "photo") ?? UIImage())
                }
                if key && !allowIcloudImages {
                    self.logger.info("Cloud image key is \(key), will return from function as cloud image download is not allowed.")
                    if !self.didShowiCloudAlertError {
                        self.alert = AlertItem(title: "view_photoOverview_enableIcloudLoadAlert_title",
                                               message: "view_photoOverview_enableIcloudLoadAlert_text",
                                               dismissOnly: false,
                                               primaryButton: ("view_photoOverview_enableIcloudLoadAlert_abort", { self.alert = nil }),
                                               secondaryButton: ("view_photoOverview_enableIcloudLoadAlert_load", {
                            self.fetchAllowed = false
                            for id in self.activeRequests {
                                manager.cancelImageRequest(id)
                            }
                            DispatchQueue.main.async {
                                self.images.removeAll()
                                self.editedImages.removeAll()
                                self.selectedImages.removeAll()
                            }
                            UserDefaults.standard.set(true, forKey: Constants.includeIcloudImages)
                            self.fetchAllPhotos()
                        }))
                        self.didShowiCloudAlertError = true
                        return
                    }
                }
            }

            if let res = result {
                self.createAndAddImage(asset, res)
                if let degraded = info?["PHImageResultIsDegradedKey"] as? NSNumber, let id = info?["PHImageResultRequestIDKey"] as? NSNumber {
                    if !degraded.boolValue {
                        self.logger.info("removing id \(id)")
                    }
                }
            }
        })
    }

    private func handleCloudDownloadProgress(_ progress: Double, _ error: Error?, _ stop: UnsafeMutablePointer<ObjCBool>, _ additionalInfo: [AnyHashable : Any]?) {
        if let error = error, self.alert != nil, !self.didShowiCloudAlertError {
            self.didShowiCloudAlertError = true
            self.alert = AlertItem(title: NSLocalizedString("view_photoOverview_icloudLoadAlert_title", comment: ""),
                                   message: String(format: NSLocalizedString("view_photoOverview_icloudLoadAlert_text", comment: ""), "\n", error.localizedDescription),
                                   dismissOnly: true,
                                   dismissButton: ("Ok", { self.alert = nil }))
        }

        self.logger.warning("Progress is \(progress), error occured: \(error?.localizedDescription ?? "none", privacy: .public)\n\(additionalInfo?.description ?? "no additional info", privacy: .public)")
    }

    // MARK: PhotoDuplicationCallbacks
    private func handleDuplicationCompletion() {
        self.reset()
    }

    private func handleDuplicationProgress(_ assets: [String]) {
        guard var documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // log
            return
        }

        documentsDirectory.appendPathComponent(Constants.imageFileName)

        var indices = ""

        for id in assets {
            indices.append(id + "\n")
        }

        if !FileManager.default.fileExists(atPath: documentsDirectory.path) {
            FileManager.default.createFile(atPath: documentsDirectory.path, contents: nil, attributes: nil)
        }

        if let fileUpdater = try? FileHandle(forUpdating: documentsDirectory.absoluteURL) {
            fileUpdater.seekToEndOfFile()
            fileUpdater.write(indices.data(using: .utf8)!)
            fileUpdater.closeFile()
        }

        DispatchQueue.main.async {
            for id in assets {
                self.images.removeAll(where: {image in image.id == id })
                self.editedImages.removeAll(where: {image in image.id == id })

                self.imageIndexInformation[id] = nil
                self.allAssets[id] = nil
            }
            self.duplicatedAssets = self.duplicatedAssets.union(assets)
        }
    }

    private func handleDuplicationAlert(_ alertType: PhotoDuplicatorAlertTypes, _ error: PHPhotosError?) {
        DispatchQueue.main.async {
            switch alertType {
            case .unableToLoadCloudAssetData:
                self.alert = AlertItem(title: "view_photoOverview_enableIcloudLoadAlert_title",
                                       message: "view_photoOverview_enableIcloudLoadAlert_text",
                                       dismissOnly: false,
                                       primaryButton: ("view_photoOverview_enableIcloudLoadAlert_abort", {
                    self.alert = nil
                    // TODO: Do we want to abort or continue ?
                    //                    self.duplicator.ignoreCloudError
                    //                    self.duplicator.startDuplication()
                }),
                                       secondaryButton: ("view_photoOverview_enableIcloudLoadAlert_load", {

                    UserDefaults.standard.set(true, forKey: Constants.includeIcloudImages)
                    self.duplicator.setAssets(assets: self.getAssetsOfSelectedImages())
                    self.duplicator.startDuplication()
                }))

            case .didFinishDuplicateWithoutDelete:
                self.alert = AlertItem(title: "view_selectedPhotoOverview_alert_success_title",
                                       message: "view_selectedPhotoOverview_alert_success_message",
                                       dismissOnly: true,
                                       dismissButton: ("view_selectedPhotoOverview_alert_success_button", action: self.reset))
            case .assetCreationError:
                self.alert = AlertItem(title: "view_selectedPhotoOverview_alert_error_title",
                                       message: NSLocalizedString("view_selectedPhotoOverview_alert_error_message", comment: "") +  "\(error?.localizedDescription ?? "")",
                                       dismissOnly: true,
                                       dismissButton: ("view_selectedPhotoOverview_alert_error_dismissButton", action: self.reset))
            case .assetDeletionError:
                if let err = error, err.errorCode == PHPhotosError.Code.userCancelled.rawValue {
                    self.alert = AlertItem(title: "view_selectedPhotoOverview_alert_error_title",
                                           message: NSLocalizedString("view_selectedPhotoOverview_alert_deletionError_userCancelled_message", comment: ""),
                                           dismissOnly: true,
                                           dismissButton: ("view_selectedPhotoOverview_alert_error_dismissButton", action: self.reset))
                } else {
                    self.alert = AlertItem(title: "view_selectedPhotoOverview_alert_error_title",
                                           message: NSLocalizedString("view_selectedPhotoOverview_alert_deletionError_message", comment: "") +  "\(error?.localizedDescription ?? "")",
                                           dismissOnly: true,
                                           dismissButton: ("view_selectedPhotoOverview_alert_error_dismissButton", action: self.reset))
                }
            }
        }
    }
}

// MARK: - Calculations

extension ImageModel {
    private func calculateFreedSpace(selectAll: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            var fileSize = 0.0

            self.selectedImages.forEach { element in
                if let asset = self.allAssets[element.id] {
                    PHAssetResource.assetResources(for: asset).forEach { resouce in
                        if resouce.type == .pairedVideo || resouce.type == .fullSizePairedVideo || resouce.type == .adjustmentBasePairedVideo {
                            fileSize += resouce.value(forKey: "fileSize") as? Double ?? 0
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.approxFreedSpace = (fileSize/(1024.0*1024.0)).roundToDecimal(2)
                self.logger.info("\(self.approxFreedSpace)")
            }
        }
    }
}

// MARK: - Album information
extension ImageModel {

    fileprivate func createLPCAlbumIfNotPresent() {
        var lpcAlbum: PHAssetCollection? = nil
        let userCollections = PHCollectionList.fetchTopLevelUserCollections(with: nil)

        for index in 0..<userCollections.count {
            if userCollections.object(at: index).localizedTitle == Constants.lpcAlbumName {
                lpcAlbum = userCollections.object(at: index) as? PHAssetCollection
            }
        }

        // If it does not exist....
        if lpcAlbum == nil {
            do {
                try PHPhotoLibrary.shared().performChangesAndWait ({
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Constants.lpcAlbumName)
                })
            } catch {
                self.logger.critical("Unable to create new album!")
            }
        }
    }
}

// MARK: - Delegate Methods

extension ImageModel: PHPhotoLibraryChangeObserver {

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard self.fetchResults != nil else {
            logger.info("No images fetched yet")
            return
        }

        guard let fetchResultChangeDetails = changeInstance.changeDetails(for: self.fetchResults!) else {
            logger.info("No change in fetchResultChangeDetails")
            return;
        }
        logger.info("Contains changes - updating")

        if !(fetchResultChangeDetails.insertedObjects.isEmpty) {
            // add

            let allowCloud = UserDefaults.standard.bool(forKey: Constants.includeIcloudImages)
            let manager = PHImageManager.default()
            let option = PHImageRequestOptions()
            option.isNetworkAccessAllowed = allowCloud

            for index in 0..<fetchResultChangeDetails.insertedObjects.count {
                if !fetchAllowed { break }
                let identifier = fetchResultChangeDetails.insertedObjects[index].localIdentifier

                if self.duplicatedAssets.contains(identifier) { continue }

                self.logger.log("\(identifier)")

                allAssets[identifier] = fetchResultChangeDetails.insertedObjects[index]

                let requestId = requestImage(manager, fetchResultChangeDetails.insertedObjects[index], option, allowCloud)
                logger.info("adding id \(requestId)")
                activeRequests.insert(requestId)
            }
        }

        //        if !(fetchResultChangeDetails?.changedObjects.isEmpty ?? true) {
        //            // change
        //        }

        if !(fetchResultChangeDetails.removedObjects.isEmpty) {
            // deleted
            for asset in fetchResultChangeDetails.removedObjects {
                DispatchQueue.main.async {
                    let identifier = asset.localIdentifier
                    self.images.removeAll(where: { identifier == $0.id })
                    self.selectedImages.removeAll(where: { identifier == $0.id })
                    self.editedImages.removeAll(where: { identifier == $0.id })
                    self.imageIndexInformation.removeValue(forKey: identifier)
                    self.allAssets.removeValue(forKey: identifier)
                    self.duplicatedAssets.remove(identifier)
                }
            }
        }

        if fetchResultChangeDetails.removedObjects.isEmpty &&
            fetchResultChangeDetails.changedObjects.isEmpty &&
            fetchResultChangeDetails.insertedObjects.isEmpty {
            // this might indicate, that we had an unauthorized fetch before
            fetchAllPhotos()
        }

        let fetchAfterChanges = fetchResultChangeDetails.fetchResultAfterChanges
        self.fetchResults = fetchAfterChanges
        logger.info("Contains changes - updating finished")
    }
}

