//
//  ContentView.swift
//  SwiftBeanCountDownloaderApp
//
//  Created by Steffen Kötte on 2020-07-12.
//

import FileSelectorView
import SwiftUI

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct ContentView: View {

    @State private var ledgerURL: URL?
    @State private var userName: String = ""
    @State private var password: String = ""
    @State private var otp: String = ""
    @ObservedObject private var model: Model = Model()

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ledger:")
                FileSelectorView(allowedFileTypes: ["beancount"], url: self.$ledgerURL).disabled(model.buzy)
                Spacer()
            }.padding()
            Spacer()
            HStack {
                Spacer()
                VStack {
                    if model.buzy {
                        Text(model.activityText).frame(width: 200, height: 20)
                        ProgressView().progressViewStyle(LinearProgressViewStyle()).frame(width: 200, height: 15, alignment: .trailing)
                    } else {
                        EmptyView().frame(width: 200, height: 35, alignment: .trailing)
                    }
                    Button("Download Wealthsimple Data") {
                        model.start(ledgerURL: ledgerURL!)
                    }.disabled(ledgerURL == nil || model.buzy)
                }.padding()
            }
        }
        .sheet(isPresented: $model.showSheet) {
            switch model.sheetType {
            case .authentication:
                authenticationSheet
            case .results:
                resultsSheet
            }
        }
        .alert(isPresented: $model.showError) {
            Alert(title: Text("Error"), message: Text(model.error?.localizedDescription ?? ""), dismissButton: .default(Text("OK")))
        }
    }

    private var resultText: String {
        """
        \(model.resultBalances.map { $0.description }.joined(separator: "\n"))

        \(model.resultPrices.map { $0.description }.joined(separator: "\n"))

        \(model.resultTransactions.map { $0.description }.joined(separator: "\n\n"))
        """
    }

    private var resultsSheet: some View {
        VStack {
            Text("Results").font(.title2)
            TextEditor(text: .constant(resultText))
            Spacer()
            Button("Close") {
                model.showSheet = false
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 900, minHeight: 200, idealHeight: 400, maxHeight: .infinity)
    }

    private var authenticationSheet: some View {
        VStack {
            Text("Login").font(.title2)
            TextField("Username", text: $userName)
            SecureField("Password", text: $password)
            TextField("OTP", text: $otp)
            Button("Login") {
                model.authenticate(username: userName, password: password, otp: otp)
                password = ""
                otp = ""
            }
            .disabled(userName.isEmpty || password.isEmpty || otp.isEmpty)
            .padding(.top)
        }
        .padding()
        .frame(minWidth: 150, idealWidth: 200, maxWidth: .infinity, minHeight: 175, idealHeight: 175, maxHeight: .infinity)
    }
}
