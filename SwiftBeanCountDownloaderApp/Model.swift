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

enum WealthsimpleConversionError: Error {
    case missingCommodity(String)
    case missingAccount(String, String)
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

    @Published var needsAuthentication: Bool = false
    @Published var showError: Bool = false
    @Published private(set) var buzy: Bool = false {
        didSet {
            if !buzy {
                activityText = ""
            }
        }
    }
    @Published private(set) var balances = [Balance]()
    @Published private(set) var prices = [Price]()
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
    private var positionSubscription: AnyCancellable?

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
            self.buzy = true
            self.activityText = "Downloading Accounts"
        }
        self.wealthsimpleDownloader.getAccounts { result in
            switch result {
            case let .failure(error):
                DispatchQueue.main.async {
                    self.error = error
                    self.authenticationSuccessful = false
                    self.buzy = false
                }
            case let .success(accounts):
                self.downloadPositions(accounts: accounts)
            }
        }
    }

    private func downloadPositions(accounts: [WealthsimpleAccount]) {
        DispatchQueue.main.async {
            self.activityText = "Downloading Positions"
        }
        positionSubscription = positionPublisher
            .tryMap { value -> ([Price], [Balance]) in
                DispatchQueue.main.async {
                    self.activityText = "Converting to Beancount"
                }
                return try self.mapPositionsToPriceAndBalance(value)
            }
            .collect(accounts.count)
            .map {
                self.combinePricesAndBalances($0)
            }
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
            DispatchQueue.global(qos: .userInitiated).async {
                self.wealthsimpleDownloader.getPositions(in: account) { result in
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

    private func combinePricesAndBalances(_ values: [([Price], [Balance])]) -> ([Price], [Balance]) {
        var prices = [Price]()
        var balances = [Balance]()
        for (accountPrices, accountBalances) in values {
            prices.append(contentsOf: accountPrices)
            balances.append(contentsOf: accountBalances)
        }
        return (prices, balances)
    }

    private func mapPositionsToPriceAndBalance(_ values: (WealthsimpleAccount, [Position])) throws -> ([Price], [Balance]) {
        let (account, positions) = values
        var prices = [Price]()
        var balances = [Balance]()
        try positions.forEach {
            let (priceAmountNumber, priceDecimalDigits) = ParserUtils.parseAmountDecimalFrom(string: $0.priceAmount)
            let (balanceAmountNumber, balanceDecimalDigits) = ParserUtils.parseAmountDecimalFrom(string: $0.quantity)
            if $0.asset.type != .currency {
                try prices.append(Price(date: $0.priceDate,
                                        commoditySymbol: try ledgerSymbolFor($0.asset),
                                        amount: Amount(number: priceAmountNumber, commoditySymbol: $0.priceCurrency, decimalDigits: priceDecimalDigits)))
            }
            balances.append(Balance(date: Date(),
                                    accountName: try ledgerAccountNameFor(account, asset: $0.asset),
                                    amount: Amount(number: balanceAmountNumber, commoditySymbol: try ledgerSymbolFor($0.asset), decimalDigits: balanceDecimalDigits)))
        }
        if balances.isEmpty {
            balances.append(Balance(date: Date(),
                                    accountName: try ledgerAccountNameFor(account),
                                    amount: Amount(number: 0, commoditySymbol: account.currency, decimalDigits: 0)))
        }
        return (prices, balances)

    }

    private func ledgerSymbolFor(_ asset: Asset) throws -> String {
        if asset.type == .currency {
            return asset.symbol
        } else {
            let commodity = ledger.commodities.first {
                $0.metaData["wealthsimple"] == asset.symbol
            }
            guard let symbol = commodity?.symbol else {
                throw WealthsimpleConversionError.missingCommodity(asset.symbol)
            }
            return symbol
        }
    }

    private func ledgerAccountNameFor(_ account: WealthsimpleAccount, asset: Asset? = nil) throws -> AccountName {
        let symbol = asset != nil ? asset!.symbol : account.currency
        let type = account.accountType.rawValue
        let account = ledger.accounts.first {
            $0.metaData["wealthsimple-symbol"] == symbol &&
                $0.metaData["wealthsimple-type"] == type
        }
        guard let accountName = account?.name else {
            throw WealthsimpleConversionError.missingAccount(symbol, type)
        }
        return accountName
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

extension WealthsimpleConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingCommodity(symbol):
            return "The Commodity \(symbol) was not found in your ledger. Please make sure you add the metadata \"wealthsimple: \"\(symbol)\"\" to it."
        case let .missingAccount(symbol, type):
            return """
                The Account of type \(type) for symbol \(symbol) was not found in your ledger. \
                Please make sure you add the metadata \"wealthsimple-symbol: \"\(symbol)\" wealthsimple-type: \"\(type)\"\" to it.
                """
        }
    }
}
