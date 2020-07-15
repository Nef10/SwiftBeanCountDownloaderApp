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
        ZStack {
            VStack(alignment: .leading) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ledger:")
                    FileSelectorView(allowedFileTypes: ["beancount"], url: self.$ledgerURL)
                    Spacer()
                }.padding()
                Spacer()
                HStack {
                    Spacer()
                    Button("Download Wealthsimple Data") {
                        model.startAuthentication { success in
                            if success {
                                model.download()
                            }
                        }
                    }
                    .disabled(ledgerURL == nil)
                    .padding()
                }
            }.sheet(isPresented: $model.needsAuthentication) {
                authenticationSheet
            }
            if model.buzy {
                loadingView
            }
        }/*.sheet(isPresented: $model.showError) {
            Text("Error").font(.caption)
            Text(model.error?.localizedDescription ?? "")
        }*/
    }

    private var loadingView: some View {
        Group {
            Spacer()
            ProgressView()
            Spacer()
        }.blur(radius: 20)
    }

    private var authenticationSheet: some View {
        VStack {
            TextField("Username", text: $userName)
            SecureField("Password", text: $password)
            TextField("OTP", text: $otp)
            Button("Login") {
                model.authenticate(username: userName, password: password, otp: otp)
            }.disabled(userName.isEmpty || password.isEmpty || otp.isEmpty).padding(.top)
        }.padding().frame(minWidth: 150, idealWidth: 200, maxWidth: .infinity, minHeight: 175, idealHeight: 175, maxHeight: .infinity)
    }
}
