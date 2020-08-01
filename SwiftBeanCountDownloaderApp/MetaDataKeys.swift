//
//  MetaDataKeys.swift
//  SwiftBeanCountDownloaderApp
//
//  Created by Steffen Kötte on 2020-07-31.
//

enum MetaDataKeys {
    /// Key used to save and lookup the wealthsimple transaction id of transactions in the meta data
    static let id = "wealthsimple-id"

    /// Key used to save and the wealthsimple transaction id of a merged nrwt transactions in the meta data
    static let nrwtId = "wealthsimple-id-nrwt"

    /// Key used to save the record date of a dividend on dividend transactions
    static let dividendRecordDate = "record-date"

    /// Key used to save the number of shares for which a dividend was received on dividend transactions
    static let dividendShares = "shares"

    /// Key used to save the symbol of shares for which non resident witholding tax was paid
    static let symbol = "symbol"
}
