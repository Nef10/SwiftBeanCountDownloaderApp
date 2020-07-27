//
//  WealthsimpleLedgerMapper.swift
//  SwiftBeanCountDownloaderApp
//
//  Created by Steffen Kötte on 2020-07-26.
//

import Foundation
import SwiftBeanCountModel
import SwiftBeanCountParser
import Wealthsimple

enum WealthsimpleConversionError: Error {
    case missingCommodity(String)
    case missingAssetAccount(String, String)
    case missingIncomeAccount(String, String)
    case missingExpenseAccount(String, String)
    case unsupportedTransactionType(String)
    case unexpectedDescription(String)
    case accountNotFound(String)
}

struct WealthsimpleLedgerMapper {

    private static let dividendRegEx: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: """
             ^[^:]*:\\s+([^\\s]+)\\s+\\(record date\\)\\s+([^\\s]+)\\s+shares(,\\s+gross\\s+([-+]?[0-9]+(,[0-9]{3})*(.[0-9]+)?)\\s+([^\\s]+), convert to\\s+.*)?$
             """,
                                 options: [])
    }()

    private static let nrwtRegEx: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[^:]*: Non-resident tax withheld at source \\(([-+]?[0-9]+(,[0-9]{3})*(.[0-9]+)?)\\s+([^\\s]+), convert to\\s+.*$",
                                 options: [])
    }()

    private static let dividendDescriptionDateFormatter: DateFormatter = {
        var dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MMM-yy"
        return dateFormatter
    }()

    private static let dateFormatter: DateFormatter = {
        var dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter
    }()

    var accounts = [Wealthsimple.Account]()
    private let ledger: Ledger

    init(ledger: Ledger) {
        self.ledger = ledger
    }

    func mapPositionsToPriceAndBalance(_ positions: [Position]) throws -> ([Price], [Balance]) {
        guard let firstPosition = positions.first else {
            return ([], [])
        }
        guard let account = accounts.first( where: { $0.id == firstPosition.accountId }) else {
            throw WealthsimpleConversionError.accountNotFound(firstPosition.accountId)
        }
        var prices = [Price]()
        var balances = [Balance]()
        try positions.forEach {
            let price = amountFor(string: $0.priceAmount, in: $0.priceCurrency)
            let balance = amountFor(string: $0.quantity, in: try ledgerSymbolFor($0.asset))
            if $0.asset.type != .currency {
                try prices.append(Price(date: $0.positionDate,
                                        commoditySymbol: try ledgerSymbolFor($0.asset),
                                        amount: price))
            }
            balances.append(Balance(date: $0.positionDate,
                                    accountName: try ledgerAssetAccountNameFor(account, assetSymbol: $0.asset.symbol),
                                    amount: balance))
        }
        if balances.isEmpty {
            balances.append(Balance(date: Date(),
                                    accountName: try ledgerAssetAccountNameFor(account),
                                    amount: Amount(number: 0, commoditySymbol: account.currency, decimalDigits: 0)))
        }
        return (prices, balances)

    }

    func mapTransactionsToPriceAndTransactions(_ wealthsimpleTransactions: [Wealthsimple.Transaction]) throws -> ([Price], [SwiftBeanCountModel.Transaction]) {
        guard let firstTransaction = wealthsimpleTransactions.first else {
            return ([], [])
        }
        guard let account = accounts.first( where: { $0.id == firstTransaction.accountId }) else {
            throw WealthsimpleConversionError.accountNotFound(firstTransaction.accountId)
        }
        var prices = [Price]()
        var transactions = [SwiftBeanCountModel.Transaction]()
        try wealthsimpleTransactions.forEach {
            let (price, transaction) = try mapTransaction($0, in: account)
            transactions.append(transaction)
            if let price = price {
                prices.append(price)
            }
        }
        return (prices, transactions)
    }

    private func amountFor(string: String, in commoditySymbol: String, negate: Bool = false, inverse: Bool = false) -> Amount {
        var (number, decimalDigits) = ParserUtils.parseAmountDecimalFrom(string: string)
        if negate {
            number = -number
        }
        if inverse {
            number = 1 / number
        }
        return Amount(number: number, commoditySymbol: commoditySymbol, decimalDigits: decimalDigits)
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

    private func ledgerSymbolFor(_ assetSymbol: String) throws -> String {
        let commodity = ledger.commodities.first {
            $0.metaData["wealthsimple"] == assetSymbol
        }
        guard let symbol = commodity?.symbol else {
            throw WealthsimpleConversionError.missingCommodity(assetSymbol)
        }
        return symbol
    }

    private func ledgerAssetAccountNameFor(_ account: Wealthsimple.Account, assetSymbol: String? = nil) throws -> AccountName {
        let symbol = assetSymbol ?? account.currency
        let type = account.accountType.rawValue
        let account = ledger.accounts.first {
            $0.name.accountType == .asset &&
                $0.metaData["wealthsimple-symbol"] == symbol &&
                $0.metaData["wealthsimple-type"] == type
        }
        guard let accountName = account?.name else {
            throw WealthsimpleConversionError.missingAssetAccount(symbol, type)
        }
        return accountName
    }

    private func ledgerIncomeAccountNameFor(_ account: Wealthsimple.Account, assetSymbol: String? = nil) throws -> AccountName {
        let symbol = assetSymbol ?? account.currency
        let type = account.accountType.rawValue
        let account = ledger.accounts.first {
            $0.name.accountType == .income &&
                $0.metaData["wealthsimple-symbol"] == symbol &&
                $0.metaData["wealthsimple-type"] == type
        }
        guard let accountName = account?.name else {
            throw WealthsimpleConversionError.missingIncomeAccount(symbol, type)
        }
        return accountName
    }

    private func ledgerExpenseAccountNameFor(_ account: Wealthsimple.Account, type symbol: String) throws -> AccountName {
        let type = account.accountType.rawValue
        let account = ledger.accounts.first {
            $0.name.accountType == .expense &&
                $0.metaData["wealthsimple-type"] == type &&
                $0.metaData["wealthsimple-symbol"] == symbol
        }
        guard let accountName = account?.name else {
            throw WealthsimpleConversionError.missingExpenseAccount(symbol, type)
        }
        return accountName
    }

    // swiftlint:disable:next function_body_length
    private func mapTransaction(_ transaction: Wealthsimple.Transaction, in account: Wealthsimple.Account) throws -> (Price?, SwiftBeanCountModel.Transaction) {
        let marketPrice = amountFor(string: transaction.marketPriceAmount, in: transaction.marketPriceCurrency)
        //let marketValue = amountFor(string: transaction.marketValueAmount, in: transaction.marketValueCurrency)
        let netCash = amountFor(string: transaction.netCashAmount, in: transaction.netCashCurrency)
        let negatedNetCash = amountFor(string: transaction.netCashAmount, in: transaction.netCashCurrency, negate: true)
        let fxAmount = amountFor(string: transaction.fxRate, in: transaction.marketPriceCurrency, inverse: true)
        let cashTypes: [Wealthsimple.Transaction.TransactionType] = [.fee, .contribution, .deposit, .refund]
        let quantitySymbol = cashTypes.contains(transaction.transactionType) ? transaction.symbol : try ledgerSymbolFor(transaction.symbol)
        let quantity = amountFor(string: transaction.quantity, in: quantitySymbol)
        var payee = ""
        var narration = ""
        var metaData = ["id": transaction.id]
        var posting1, posting2: Posting
        var price: Price?
        switch transaction.transactionType {
        case .buy:
            let useFx = transaction.marketValueCurrency != transaction.netCashCurrency
            let cost = try Cost(amount: marketPrice, date: nil, label: nil)
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash, price: useFx ? fxAmount : nil)
            posting2 = Posting(accountName: try ledgerAssetAccountNameFor(account, assetSymbol: transaction.symbol), amount: quantity, cost: cost)
            price = try Price(date: transaction.processDate, commoditySymbol: transaction.symbol, amount: marketPrice)
        case .sell:
            let useFx = transaction.marketValueCurrency != transaction.netCashCurrency
            let cost = try Cost(amount: nil, date: nil, label: nil)
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash, price: useFx ? fxAmount : nil)
            posting2 = Posting(accountName: try ledgerAssetAccountNameFor(account, assetSymbol: transaction.symbol), amount: quantity, price: marketPrice, cost: cost)
            price = try Price(date: transaction.processDate, commoditySymbol: transaction.symbol, amount: marketPrice)
        case .dividend:
            let (date, shares, foreignAmount) = try parseDividendDescription(transaction.description)
            metaData["record-date"] = date
            metaData["shares"] = shares
            var income = negatedNetCash
            var price: Amount?
            if let amount = foreignAmount {
                income = amount
                price = Amount(number: fxAmount.number, commoditySymbol: amount.commoditySymbol, decimalDigits: fxAmount.decimalDigits)
            }
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash, price: price)
            posting2 = Posting(accountName: try ledgerIncomeAccountNameFor(account, assetSymbol: transaction.symbol), amount: income)
        case .fee:
            payee = "Wealthsimple"
            narration = transaction.description
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash)
            posting2 = Posting(accountName: try ledgerExpenseAccountNameFor(account, type: transaction.transactionType.rawValue), amount: negatedNetCash)
        case .contribution, .deposit:
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash)
            posting2 = Posting(accountName: try ledgerAssetAccountNameFor(account, assetSymbol: transaction.transactionType.rawValue), amount: negatedNetCash)
        case .refund:
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash)
            posting2 = Posting(accountName: try ledgerIncomeAccountNameFor(account, assetSymbol: transaction.transactionType.rawValue), amount: negatedNetCash)
        case .nonResidentWithholdingTax:
            let amount = try parseNRWtDescription(transaction.description)
            let price = Amount(number: fxAmount.number, commoditySymbol: amount.commoditySymbol, decimalDigits: fxAmount.decimalDigits)
            posting1 = Posting(accountName: try ledgerAssetAccountNameFor(account), amount: netCash, price: price)
            posting2 = Posting(accountName: try ledgerExpenseAccountNameFor(account, type: transaction.transactionType.rawValue), amount: amount)
        default:
            throw WealthsimpleConversionError.unsupportedTransactionType(transaction.transactionType.rawValue)
        }
        let transactionMetaData = TransactionMetaData(date: transaction.effectiveDate, payee: payee, narration: narration, flag: .complete, tags: [], metaData: metaData)
        return (price, SwiftBeanCountModel.Transaction(metaData: transactionMetaData, postings: [posting1, posting2]))
    }

    // swiftlint:disable:next large_tuple
    private func parseDividendDescription(_ string: String) throws -> (String, String, Amount?) {
        let matches = ParserUtils.match(regex: Self.dividendRegEx, in: string)
        guard
            matches.count == 1,
            let date = Self.dividendDescriptionDateFormatter.date(from: matches[0][1])
        else {
            throw WealthsimpleConversionError.unexpectedDescription(string)
        }
        let match = matches[0]
        let dateString = Self.dateFormatter.string(from: date)
        let shares = match[2]
        var amount: Amount?
        if !match[4].isEmpty {
            amount = amountFor(string: match[4], in: match[7], negate: true)
        }
        return (dateString, shares, amount)
    }

    private func parseNRWtDescription(_ string: String) throws -> Amount {
        let matches = ParserUtils.match(regex: Self.nrwtRegEx, in: string)
        guard matches.count == 1 else {
            throw WealthsimpleConversionError.unexpectedDescription(string)
        }
        let match = matches[0]
        return amountFor(string: match[1], in: match[4])
    }

}

extension WealthsimpleConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingCommodity(symbol):
            return "The Commodity \(symbol) was not found in your ledger. Please make sure you add the metadata \"wealthsimple: \"\(symbol)\"\" to it."
        case let .missingAssetAccount(symbol, type):
            return """
                The asset account for account type \(type) and symbol \(symbol) was not found in your ledger. \
                Please make sure you add the metadata \"wealthsimple-symbol: \"\(symbol)\" wealthsimple-type: \"\(type)\"\" to it.
                """
        case let .missingIncomeAccount(symbol, type):
            return """
                The income account for account type \(type) and symbol \(symbol) was not found in your ledger. \
                Please make sure you add the metadata \"wealthsimple-symbol: \"\(symbol)\" wealthsimple-type: \"\(type)\"\" to it.
                """
        case let .missingExpenseAccount(symbol, type):
            return """
                The expense account for account type \(type) and expense type \(symbol) was not found in your ledger. \
                Please make sure you add the metadata \"wealthsimple-type: \"\(type)\" wealthsimple-symbol: \"\(symbol)\"\" to it.
                """
        case let .unsupportedTransactionType(type):
            return "Transactions of Type \(type) are currently not yet supported"
        case let .unexpectedDescription(string):
            return "Wealthsimple returned an unexpected description for a transaction: \(string)"
        case let .accountNotFound(accountId):
            return "Wealthsimple returned an element from an account with id \(accountId) which was not found."
        }
    }
}
