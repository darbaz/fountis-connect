import SwiftUI
import FountisConnect

struct ContentView: View {
    @State private var log: [String] = ["events appear here"]
    @State private var signedIn = true
    @State private var listening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Acme Phone").font(.largeTitle.bold())
            Text("A made-up partner app. Fake user: a 33-year-old woman in Erbil.").foregroundStyle(.secondary)
            HStack {
                Button("Show study") {
                    Task {
                        let r = await FountisConnect.show()
                        add("show() -> \(r)")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(signedIn ? "Sign out" : "Sign in") {
                    Task {
                        signedIn.toggle()
                        await SampleSession.shared.setSignedIn(signedIn)
                        if !signedIn { FountisConnect.signOut() }
                        add(signedIn ? "signed in" : "signed out")
                    }
                }
                .buttonStyle(.bordered)
            }
            ScrollView {
                Text(log.joined(separator: "\n")).font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .onAppear {
            // onAppear fires again each time the study screen is dismissed; register the listener once.
            guard !listening else { return }
            listening = true
            FountisConnect.onEvent { e in add("\(e.type) \(e.offerId ?? "")") }
        }
    }

    private func add(_ s: String) { log.insert(s, at: 0) }
}
