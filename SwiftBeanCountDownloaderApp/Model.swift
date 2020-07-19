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
    @Published private(set) var buzy: Bool = false {
        didSet {
            if !buzy {
                activityText = ""
            }
        }
    }
    @Published private(set) var activityText = ""
    @Published private(set) var error: Error? {
        didSet {
            showError = error != nil
        }
    }

    private let credentialStorage = KeyChainCredentialStorage()
    private let positionPublisher = PassthroughSubject<(WealthsimpleAccount, [Position]), Position.PositionError>()
    private var wealthsimpleDownloader: WealthsimpleDownloader!
    private var ledger: Ledger!
    private var authenticationSuccessful = false
    private var authenticationFinishedCallback: ((String, String, String) -> Void)? {
        didSet {
            needsAuthentication = authenticationFinishedCallback != nil
        }
    }
    private var cancellable: AnyCancellable?

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
        self.activityText = "Loading Ledger"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.ledger = try Parser.parse(contentOf: ledgerURL)
                self.download()
            } catch {
                self.error = error
            }
        }
    }

    func download() {
        startAuthentication { success in
            guard success else {
                return
            }
            DispatchQueue.main.async {
                self.downloadAccounts()
            }
        }
    }

    private func downloadAccounts() {
        self.buzy = true
        self.activityText = "Downloading Accounts"
        self.wealthsimpleDownloader.getAccounts { result in
            DispatchQueue.main.async {
                switch result {
                case let .failure(error):
                    self.error = error
                    self.authenticationSuccessful = false
                    self.buzy = false
                case let .success(accounts):
                    self.downloadPositions(accounts: accounts)
                }
            }
        }
    }

    private func downloadPositions(accounts: [WealthsimpleAccount]) {
        self.activityText = "Downloading Positions"
        cancellable = positionPublisher
            .tryMap { value -> ([Price], [Balance]) in
                DispatchQueue.main.async {
                    self.activityText = "Converting to Beancount"
                }
                return try self.mapPositionsToPriceAndBalance(value)
            }
            .collect(accounts.count)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    self.error = error
                    self.authenticationSuccessful = false
                }
                self.buzy = false
            }, receiveValue: { result in
                print(".sink() data received \(result)")
                self.buzy = false
            })

        for account in accounts {
            self.wealthsimpleDownloader.getPositions(in: account) { result in
                DispatchQueue.global(qos: .userInitiated).async {
                    switch result {
                    case let .failure(error):
                        self.positionPublisher.send(completion: .failure(error))
                    case let .success(positions):
                        self.positionPublisher.send((account, positions))
                    }
                }
            }
        }
    }

    private func mapPositionsToPriceAndBalance(_ values: (WealthsimpleAccount, [Position])) throws -> ([Price], [Balance]) {
        let (account, positions) = values
        let accountName = try AccountName("Assets:\(account.accountType.rawValue)")
        var prices = [Price]()
        var balances = [Balance]()
        try positions.forEach {
            let (priceAmountNumber, priceDecimalDigits) = ParserUtils.parseAmountDecimalFrom(string: $0.priceAmount)
            let (balanceAmountNumber, balanceDecimalDigits) = ParserUtils.parseAmountDecimalFrom(string: $0.quantity)
            if $0.asset.type != .currency {
                try prices.append(Price(date: $0.priceDate,
                                        commoditySymbol: $0.asset.symbol,
                                        amount: Amount(number: priceAmountNumber, commoditySymbol: $0.priceCurrency, decimalDigits: priceDecimalDigits)))
            }
            balances.append(Balance(date: Date(),
                                    accountName: accountName,
                                    amount: Amount(number: balanceAmountNumber, commoditySymbol: $0.asset.symbol, decimalDigits: balanceDecimalDigits)))
        }
        if balances.isEmpty {
            balances.append(Balance(date: Date(),
                                    accountName: accountName,
                                    amount: Amount(number: 0, commoditySymbol: account.currency, decimalDigits: 0)))
        }
        return (prices, balances)

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
                self.buzy = false
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
