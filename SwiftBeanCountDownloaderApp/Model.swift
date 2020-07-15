//
//  Model.swift
//  SwiftBeanCountDownloaderApp
//
//  Created by Steffen Kötte on 2020-07-14.
//

import KeychainAccess
import SwiftUI
import WealthsimpleDownloader

class Model: ObservableObject {

    class KeyChainCredentialStorage: CredentialStorage {

        let keychain = Keychain(service: "com.github.nef10.swiftbeancountdownloaderapp")

        func save(_ value: String, for key: String) {
            keychain[key] = value
        }

        func read(_ key: String) -> String? {
            keychain[key]
        }

    }

    @Published var needsAuthentication: Bool = false
    @Published var showError: Bool = false
    @Published private(set) var buzy: Bool = false
    @Published private(set) var error: Error? {
        didSet {
            showError = error != nil
        }
    }

    private let credentialStorage = KeyChainCredentialStorage()
    private var wealthsimpleDownloader: WealthsimpleDownloader!
    private var authenticationFinishedCallback: ((String, String, String) -> Void)? {
        didSet {
            needsAuthentication = authenticationFinishedCallback != nil
        }
    }

    init() {
        wealthsimpleDownloader = WealthsimpleDownloader(authenticationCallback: authenticationCallback, credentialStorage: credentialStorage)
    }

    func startAuthentication(completion: @escaping (Bool) -> Void) {
        self.buzy = true
        wealthsimpleDownloader.authenticate { error in
            DispatchQueue.main.async {
                self.buzy = false
                self.error = error
                completion(error == nil)
            }
        }
    }

    func authenticate(username: String, password: String, otp: String) {
        let callback = authenticationFinishedCallback
        authenticationFinishedCallback = nil
        callback?(username, password, otp)
    }

    func download() {
        DispatchQueue.main.async {
            self.buzy = true
            self.wealthsimpleDownloader.getAccounts {
                print($0)
                DispatchQueue.main.async {
                    self.buzy = false
                }
            }
        }
    }

    private func authenticationCallback(callback: @escaping ((String, String, String) -> Void)) {
        DispatchQueue.main.async {
            self.buzy = true
            self.authenticationFinishedCallback = callback
        }
    }

}
