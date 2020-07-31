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

/// Helper functions to transform downloaded wealthsimple data into SwiftBeanCountModel types
public struct WealthsimpleLedgerMapper {

    /// Key used to save and lookup the wealthsimple transaction id of transactions in the meta data
    static let idMetaDataKey = "wealthsimple-id"

    /// Key used to save and the wealthsimple transaction id of a merged nrwt transactions in the meta data
    static let nrwtIdMetaDataKey = "wealthsimple-id-nrwt"

    /// Payee used for fee transactions
    private static let payee = "Wealthsimple"

    /// Key used to save the record date of a dividend on dividend transactions
    private static let dividendRecordDateMetaDataKey = "record-date"

    /// Key used to save the number of shares for which a dividend was received on dividend transactions
    private static let dividendSharesMetaDataKey = "shares"

    /// Key used to save the symbol of shares for which non resident witholding tax was paid
    private static let symbolMetaDataKey = "symbol"

    /// Value used for the key of the rounding account
    private static let roundingValue = "rounding"

    /// Regex to parse the amount in foreign currency and the record date on dividend transactions from the description
    private static let dividendRegEx: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: """
             ^[^:]*:\\s+([^\\s]+)\\s+\\(record date\\)\\s+([^\\s]+)\\s+shares(,\\s+gross\\s+([-+]?[0-9]+(,[0-9]{3})*(.[0-9]+)?)\\s+([^\\s]+), convert to\\s+.*)?$
             """,
                                 options: [])
    }()

    /// Regex to parse the amount in foreign currency on non residend tax withholding transactions from the description
    private static let nrwtRegEx: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[^:]*: Non-resident tax withheld at source \\(([-+]?[0-9]+(,[0-9]{3})*(.[0-9]+)?)\\s+([^\\s]+), convert to\\s+.*$",
                                 options: [])
    }()

    /// Date formatter to parse the record date of dividends from the description of dividend transaction
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

    /// Downloaded Wealthsimple accounts
    ///
    /// Need to be set before attempting to map positions or transactions
    public var accounts = [Wealthsimple.Account]()

    private let lookup: LedgerLookup

    /// Create a WealthsimpleLedgerMapper
    /// - Parameter ledger: Ledger to look up accounts, commodities or duplicate entries in
    public init(ledger: Ledger) {
        self.lookup = LedgerLookup(ledger)
    }

    static func amount(for string: String, in commoditySymbol: String, negate: Bool = false, inverse: Bool = false) -> Amount {
        var (number, decimalDigits) = ParserUtils.parseAmountDecimalFrom(string: string)
        if decimalDigits < 2 {
            decimalDigits = 2 // Wealthsimple cuts of an ending 0 in the second digit. However, all amounts we deal with have at least 2 digits
        }
        if negate {
            number = -number
        }
        if inverse {
            number = 1 / number
        }
        return Amount(number: number, commoditySymbol: commoditySymbol, decimalDigits: decimalDigits)
    }

    /// Maps downloaded wealthsimple positions from one account to SwiftBeanCountModel prices and balances
    ///
    /// It also removes prices and balances which are already existing in the ledger
    ///
    /// Notes:
    ///  - Do not call with transactions from different accounts
    ///  - Make sure to set accounts on this class to the Wealthsimple accounts first
    ///  - Do not assume that the count of input and balance output is the same
    ///
    /// - Parameter positions: downloaded positions from one account
    /// - Throws: WealthsimpleConversionError
    /// - Returns: Prices and Balances
    public func mapPositionsToPriceAndBalance(_ positions: [Position]) throws -> ([Price], [Balance]) {
        guard let firstPosition = positions.first else {
            return ([], [])
        }
        guard let account = accounts.first( where: { $0.id == firstPosition.accountId }) else {
            throw WealthsimpleConversionError.accountNotFound(firstPosition.accountId)
        }
        var prices = [Price]()
        var balances = [Balance]()
        try positions.forEach {
            let price = Self.amount(for: $0.priceAmount, in: $0.priceCurrency)
            let balanceAmount = Self.amount(for: $0.quantity, in: try lookup.ledgerSymbol(for: $0.asset))
            if $0.asset.type != .currency {
                let price = try Price(date: $0.positionDate,
                                      commoditySymbol: try lookup.ledgerSymbol(for: $0.asset),
                                      amount: price)
                if !lookup.doesPriceExistInLedger(price) {
                    prices.append(price)
                }
            }
            let balance = Balance(date: $0.positionDate,
                                  accountName: try lookup.ledgerAccountName(for: account, ofType: .asset, symbol: $0.asset.symbol),
                                  amount: balanceAmount)
            if !lookup.doesBalanceExistInLedger(balance) {
                balances.append(balance)
            }
        }
        if positions.isEmpty {
            let balance = Balance(date: Date(),
                                  accountName: try lookup.ledgerAccountName(for: account, ofType: .asset),
                                  amount: Amount(number: 0, commoditySymbol: account.currency, decimalDigits: 0))
            if !lookup.doesBalanceExistInLedger(balance) {
                balances.append(balance)
            }
        }
        return (prices, balances)
    }

    /// Maps downloaded wealthsimple transactions from one account to SwiftBeanCountModel transactions and prices
    ///
    /// It also removes transactions and prices which are already existing in the ledger
    ///
    /// Notes:
    ///  - Do not call with transactions from different accounts
    ///  - Make sure to set accounts on this class to the Wealthsimple accounts first
    ///  - Do not assume that the count of input and transaction output is the same, as this function consolidates transactions
    ///
    /// - Parameter wealthsimpleTransactions: downloaded transactions from one account
    /// - Throws: WealthsimpleConversionError
    /// - Returns: Prices and Transactions
    public func mapTransactionsToPriceAndTransactions(_ wealthsimpleTransactions: [Wealthsimple.Transaction]) throws -> ([Price], [SwiftBeanCountModel.Transaction]) {
        guard let firstTransaction = wealthsimpleTransactions.first else {
            return ([], [])
        }
        guard let account = accounts.first( where: { $0.id == firstTransaction.accountId }) else {
            throw WealthsimpleConversionError.accountNotFound(firstTransaction.accountId)
        }
        var nrwtTransactions = wealthsimpleTransactions.filter {
            $0.transactionType == .nonResidentWithholdingTax
        }
        let transactionsToMap = wealthsimpleTransactions.filter {
            $0.transactionType != .nonResidentWithholdingTax
        }
        var prices = [Price]()
        var transactions = [SwiftBeanCountModel.Transaction]()
        for wealthsimpleTransaction in transactionsToMap {
            var (price, transaction) = try mapTransaction(wealthsimpleTransaction, in: account)
            if !lookup.doesTransactionExistInLedger(transaction) {
                if wealthsimpleTransaction.transactionType == .dividend {
                    if let index = nrwtTransactions.firstIndex(where: {
                        $0.symbol == wealthsimpleTransaction.symbol && $0.processDate == wealthsimpleTransaction.processDate
                    }) {
                        transaction = try mergeNRWT(transaction: nrwtTransactions[index], withDividendTransaction: transaction, in: account)
                        nrwtTransactions.remove(at: index)
                    }
                }
                transactions.append(transaction)
            }
            if let price = price,
               !lookup.doesPriceExistInLedger(price) {
                prices.append(price)
            }
        }
        for wealthsimpleTransaction in nrwtTransactions { // add nrwt transactions which could not be merged
            let (price, transaction) = try mapTransaction(wealthsimpleTransaction, in: account)
            if !lookup.doesTransactionExistInLedger(transaction) {
                transactions.append(transaction)
            }
            if let price = price,
               !lookup.doesPriceExistInLedger(price) {
                prices.append(price)
            }
        }
        return (prices, transactions)
    }

    /// Merges a non resident witholding tax transaction with the corresponding dividend transactin
    /// - Parameters:
    ///   - transaction: the non resident witholding tax transaction
    ///   - dividend: the dividend transaction
    ///   - account: account of the transactions
    /// - Throws: WealthsimpleConversionError
    /// - Returns: Merged transaction
    private func mergeNRWT(
        transaction: Wealthsimple.Transaction,
        withDividendTransaction dividend: SwiftBeanCountModel.Transaction,
        in account: Wealthsimple.Account
    ) throws -> SwiftBeanCountModel.Transaction {
        var postings = [Posting]()
        // income stays the same
        postings.append(dividend.postings.first { $0.accountName.accountType == .income }!)
        // generate expense
        let expenseAmount = try parseNRWTDescription(transaction.description)
        let expense = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .expense, symbol: transaction.transactionType.rawValue), amount: expenseAmount)
        postings.append(expense)
        // adjust asset
        let oldAsset = dividend.postings.first { $0.accountName.accountType == .asset }!
        let assetAmount = (oldAsset.amount + transaction.netCash).amountFor(symbol: transaction.netCashCurrency)
        let asset = Posting(accountName: oldAsset.accountName, amount: assetAmount, price: oldAsset.price, cost: oldAsset.cost, metaData: oldAsset.metaData)
        postings.append(asset)
        var metaData = dividend.metaData.metaData
        metaData[Self.nrwtIdMetaDataKey] = transaction.id
        let transactionMetaData = TransactionMetaData(date: dividend.metaData.date,
                                                      payee: dividend.metaData.payee,
                                                      narration: dividend.metaData.narration,
                                                      flag: dividend.metaData.flag,
                                                      tags: dividend.metaData.tags,
                                                      metaData: metaData)
        return SwiftBeanCountModel.Transaction(metaData: transactionMetaData, postings: postings)
    }

    // swiftlint:disable:next function_body_length
    private func mapTransaction(_ transaction: Wealthsimple.Transaction, in account: Wealthsimple.Account) throws -> (Price?, SwiftBeanCountModel.Transaction) {
        let assetAccountName = try lookup.ledgerAccountName(for: account, ofType: .asset)
        var payee = ""
        var narration = ""
        var metaData = [Self.idMetaDataKey: transaction.id]
        var posting1, posting2: Posting
        var price: Price?
        switch transaction.transactionType {
        case .buy:
            let cost = try Cost(amount: transaction.marketPrice, date: nil, label: nil)
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash, price: transaction.useFx ? transaction.fxAmount : nil)
            posting2 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .asset, symbol: transaction.symbol),
                               amount: try transaction.quantityAmount(lookup: lookup),
                               cost: cost)
            price = try Price(date: transaction.processDate, commoditySymbol: transaction.symbol, amount: transaction.marketPrice)
        case .sell:
            let cost = try Cost(amount: nil, date: nil, label: nil)
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash, price: transaction.useFx ? transaction.fxAmount : nil)
            let accountName2 = try lookup.ledgerAccountName(for: account, ofType: .asset, symbol: transaction.symbol)
            posting2 = Posting(accountName: accountName2, amount: try transaction.quantityAmount(lookup: lookup), price: transaction.marketPrice, cost: cost)
            price = try Price(date: transaction.processDate, commoditySymbol: transaction.symbol, amount: transaction.marketPrice)
        case .dividend:
            let (date, shares, foreignAmount) = try parseDividendDescription(transaction.description)
            metaData[Self.dividendRecordDateMetaDataKey] = date
            metaData[Self.dividendSharesMetaDataKey] = shares
            var income = transaction.negatedNetCash
            var price: Amount?
            if let amount = foreignAmount {
                income = amount
                price = Amount(number: transaction.fxAmount.number, commoditySymbol: amount.commoditySymbol, decimalDigits: transaction.fxAmount.decimalDigits)
            }
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash, price: price)
            posting2 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .income, symbol: transaction.symbol), amount: income)
        case .fee:
            payee = Self.payee
            narration = transaction.description
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash)
            posting2 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .expense, symbol: transaction.transactionType.rawValue),
                               amount: transaction.negatedNetCash)
        case .contribution, .deposit:
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash)
            posting2 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .asset, symbol: transaction.transactionType.rawValue),
                               amount: transaction.negatedNetCash)
        case .refund:
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash)
            posting2 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .income, symbol: transaction.transactionType.rawValue),
                               amount: transaction.negatedNetCash)
        case .nonResidentWithholdingTax:
            metaData[Self.symbolMetaDataKey] = transaction.symbol
            let amount = try parseNRWTDescription(transaction.description)
            let price = Amount(number: transaction.fxAmount.number, commoditySymbol: amount.commoditySymbol, decimalDigits: transaction.fxAmount.decimalDigits)
            posting1 = Posting(accountName: assetAccountName, amount: transaction.netCash, price: price)
            posting2 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .expense, symbol: transaction.transactionType.rawValue), amount: amount)
        default:
            throw WealthsimpleConversionError.unsupportedTransactionType(transaction.transactionType.rawValue)
        }
        let transactionMetaData = TransactionMetaData(date: transaction.effectiveDate, payee: payee, narration: narration, flag: .complete, tags: [], metaData: metaData)
        var transaction = SwiftBeanCountModel.Transaction(metaData: transactionMetaData, postings: [posting1, posting2])
        if !lookup.isTransactionValid(transaction) {
            let posting3 = Posting(accountName: try lookup.ledgerAccountName(for: account, ofType: .expense, symbol: Self.roundingValue),
                                   amount: lookup.roundingBalance(transaction))
            transaction = SwiftBeanCountModel.Transaction(metaData: transactionMetaData, postings: [posting1, posting2, posting3])
        }
        return (price, transaction)
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
        var resultAmount: Amount?
        if !match[4].isEmpty {
            resultAmount = Self.amount(for: match[4], in: match[7], negate: true)
        }
        return (dateString, shares, resultAmount)
    }

    private func parseNRWTDescription(_ string: String) throws -> Amount {
        let matches = ParserUtils.match(regex: Self.nrwtRegEx, in: string)
        guard matches.count == 1 else {
            throw WealthsimpleConversionError.unexpectedDescription(string)
        }
        let match = matches[0]
        return Self.amount(for: match[1], in: match[4])
    }

}

extension Wealthsimple.Transaction {

    var marketPrice: Amount {
        WealthsimpleLedgerMapper.amount(for: marketPriceAmount, in: marketPriceCurrency)
    }
    var netCash: Amount {
        WealthsimpleLedgerMapper.amount(for: netCashAmount, in: netCashCurrency)
    }
    var negatedNetCash: Amount {
        WealthsimpleLedgerMapper.amount(for: netCashAmount, in: netCashCurrency, negate: true)
    }
    var fxAmount: Amount {
        WealthsimpleLedgerMapper.amount(for: fxRate, in: marketPriceCurrency, inverse: true)
    }
    var cashTypes: [Wealthsimple.Transaction.TransactionType] {
        [.fee, .contribution, .deposit, .refund]
    }
    var useFx: Bool {
        marketValueCurrency != netCashCurrency
    }

    func quantitySymbol(lookup: LedgerLookup) throws -> String {
        cashTypes.contains(transactionType) ? symbol : try lookup.ledgerSymbol(for: symbol)
    }

    func quantityAmount(lookup: LedgerLookup) throws -> Amount {
        WealthsimpleLedgerMapper.amount(for: quantity, in: try quantitySymbol(lookup: lookup))
    }

}
