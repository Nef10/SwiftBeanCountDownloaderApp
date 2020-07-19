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
        .sheet(isPresented: $model.needsAuthentication) {
            authenticationSheet
        }
        .alert(isPresented: $model.showError) {
            Alert(title: Text("Error"), message: Text(model.error?.localizedDescription ?? ""), dismissButton: .default(Text("OK")))
        }
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
