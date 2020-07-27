//
//  Model.swift
//  SwiftBeanCountDownloaderApp
//
//  Created by Steffen Kötte on 2020-07-14.
//

import Combine
import KeychainAccess
import SwiftBeanCountModel
import SwiftBeanCountParser
import SwiftUI
import Wealthsimple

enum SheetType {
    case authentication
    case results
}

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

    @Published var showSheet: Bool = false {
        didSet {
            if showSheet {
                self.buzy = false
            }
        }
    }
    @Published var showError: Bool = false {
        didSet {
            if showError {
                self.buzy = false
            }
        }
    }
    @Published private(set) var sheetType = SheetType.authentication
    @Published private(set) var buzy: Bool = false {
        didSet {
            if !buzy {
                activityText = ""
            }
        }
    }
    @Published private(set) var resultPrices = [Price]()
    @Published private(set) var resultBalances = [Balance]()
    @Published private(set) var resultTransactions = [SwiftBeanCountModel.Transaction]()
    @Published private(set) var activityText = ""
    @Published private(set) var error: Error? {
        didSet {
            showError = error != nil
        }
    }

    private let sixtyTwoDays = -60 * 60 * 24 * 62.0
    private let credentialStorage = KeyChainCredentialStorage()
    private let positionPublisher = PassthroughSubject<[Position], Position.PositionError>()
    private let transactionPublisher = PassthroughSubject<[Wealthsimple.Transaction], Wealthsimple.Transaction.TransactionError>()
    private var wealthsimpleDownloader: WealthsimpleDownloader!
    private var mapper: WealthsimpleLedgerMapper!
    private var resultAccounts = [Wealthsimple.Account]()
    private var ledger: Ledger! {
        didSet {
            mapper = WealthsimpleLedgerMapper(ledger: ledger)
        }
    }
    private var authenticationSuccessful = false
    private var authenticationFinishedCallback: ((String, String, String) -> Void)? {
        didSet {
            if authenticationFinishedCallback != nil {
                sheetType = .authentication
                showSheet = true
            }
        }
    }
    private var finishedPositions = false {
        didSet {
            if finishedPositions && finishedTransactions {
                sheetType = .results
                showSheet = true
            }
        }
    }
    private var finishedTransactions = false {
        didSet {
            if finishedPositions && finishedTransactions {
                sheetType = .results
                showSheet = true
            }
        }
    }
    private var positionSubscription: AnyCancellable?
    private var transactionSubscription: AnyCancellable?

    init() {
        wealthsimpleDownloader = WealthsimpleDownloader(authenticationCallback: authenticationCallback, credentialStorage: credentialStorage)
    }

    func authenticate(username: String, password: String, otp: String) {
        let callback = authenticationFinishedCallback
        authenticationFinishedCallback = nil
        callback?(username, password, otp)
    }

    func start(ledgerURL: URL) {
        self.buzy = true
        self.finishedPositions = false
        self.finishedTransactions = false
        self.resultPrices = []
        self.resultBalances = []
        self.resultTransactions = []
        self.resultAccounts = []
        self.activityText = "Loading Ledger"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.ledger = try Parser.parse(contentOf: ledgerURL)
                self.mapper.accounts = []
                self.download()
            } catch {
                self.error = error
            }
        }
    }

    private func download() {
        startAuthentication { success in
            guard success else {
                return
            }
            self.downloadAccounts()
        }
    }

    private func downloadAccounts() {
        DispatchQueue.main.async {
            self.activityText = "Downloading Accounts"
        }
        self.wealthsimpleDownloader.getAccounts { result in
            switch result {
            case let .failure(error):
                DispatchQueue.main.async {
                    self.error = error
                    self.authenticationSuccessful = false
                }
            case let .success(accounts):
                self.resultAccounts = accounts
                self.mapper.accounts = accounts
                self.downloadPositions()
            }
        }
    }

    private func downloadPositions() {
        DispatchQueue.main.async {
            self.activityText = "Downloading Positions"
        }
        positionSubscription = positionPublisher
            .tryMap { value -> ([Price], [Balance]) in
                DispatchQueue.main.async {
                    self.activityText = "Converting Positions"
                }
                return try self.mapper.mapPositionsToPriceAndBalance(value)
            }
            .collect(resultAccounts.count)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    self.error = error
                    self.authenticationSuccessful = false
                }
            }, receiveValue: { values in
                for (accountPrices, accountBalances) in values {
                    self.resultPrices.append(contentsOf: accountPrices)
                    self.resultBalances.append(contentsOf: accountBalances)
                }
                self.resultPrices.sort { $0.date < $1.date }
                self.resultBalances.sort { $0.date < $1.date }
                self.finishedPositions = true
                self.downloadTransactions()
            })

        resultAccounts.forEach { account in
            DispatchQueue.global(qos: .userInitiated).async {
                self.wealthsimpleDownloader.getPositions(in: account, date: nil) { result in
                    switch result {
                    case let .failure(error):
                        self.positionPublisher.send(completion: .failure(error))
                    case let .success(positions):
                        self.positionPublisher.send(positions)
                    }
                }
            }
        }
    }

    private func downloadTransactions() {
        DispatchQueue.main.async {
            self.activityText = "Downloading Transactions"
        }
        transactionSubscription = transactionPublisher
            .tryMap { value -> ([Price], [SwiftBeanCountModel.Transaction]) in
                DispatchQueue.main.async {
                    self.activityText = "Converting Transactions"
                }
                return try self.mapper.mapTransactionsToPriceAndTransactions(value)
            }
            .collect(resultAccounts.count)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    self.error = error
                    self.authenticationSuccessful = false
                }
            }, receiveValue: { values in
                for (accountPrices, accountTransactions) in values {
                    self.resultPrices.append(contentsOf: accountPrices)
                    self.resultTransactions.append(contentsOf: accountTransactions)
                }
                self.resultPrices.sort { $0.date < $1.date }
                self.resultTransactions.sort { $0.metaData.date < $1.metaData.date }
                self.finishedTransactions = true
            })

        resultAccounts.forEach { account in
            DispatchQueue.global(qos: .userInitiated).async {
                self.wealthsimpleDownloader.getTransactions(in: account, startDate: Date(timeIntervalSinceNow: self.sixtyTwoDays )) { result in
                    switch result {
                    case let .failure(error):
                        self.transactionPublisher.send(completion: .failure(error))
                    case let .success(transactions):
                        self.transactionPublisher.send(transactions)
                    }
                }
            }
        }
    }

    private func startAuthentication(completion: @escaping (Bool) -> Void) {
        guard !authenticationSuccessful else {
            completion(true)
            return
        }
        DispatchQueue.main.async {
            self.activityText = "Authenticating"
        }
        wealthsimpleDownloader.authenticate { error in
            DispatchQueue.main.async {
                self.error = error
                self.authenticationSuccessful = error == nil
                completion(error == nil)
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
