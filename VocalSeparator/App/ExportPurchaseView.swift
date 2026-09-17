import SwiftUI

enum AppLegalLinks {
    static func website(language: String? = Bundle.main.preferredLocalizations.first) -> URL {
        // Static, validated URLs shared by Settings and the purchase page.
        URL(string: language == "zh-Hans" ? "https://easykaraoke.xyz/" : "https://easykaraoke.xyz/en/")!
    }
    static var privacy: URL { website().appendingPathComponent("privacy", isDirectory: true) }
    static var terms: URL { website().appendingPathComponent("terms", isDirectory: true) }
}

struct ExportPurchaseView: View {
    @ObservedObject var purchases: ExportPurchaseController = .shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: purchases.isUnlocked ? "checkmark.seal.fill" : "square.and.arrow.up")
                            .font(.system(size: 28)).accessibilityHidden(true)
                        Text(purchases.isUnlocked ? String(localized: "Lifetime Export Unlocked") : String(localized: "Keep Every Performance"))
                            .font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(String(localized: "One purchase. Unlimited exports. No subscription or recurring fees."))
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                    .background(StudioTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 18) {
                        Label(String(localized: "Export backing tracks, vocals, original tracks, and recordings"), systemImage: "waveform")
                        Label(String(localized: "All formats: WAV, MP3, AAC, and ALAC"), systemImage: "music.note.list")
                        Label(String(localized: "Share and copy vocal transcriptions"), systemImage: "text.quote")
                    }.font(.subheadline).fixedSize(horizontal: false, vertical: true)

                    if purchases.isUnlocked {
                        Label(String(localized: "Your purchase is active. All exports and sharing are unlocked."), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(StudioTheme.accent)
                            .accessibilityIdentifier("purchase.unlocked")
                    } else {
                        Text(String(localized: "Unlock once to export and share. You can restore this purchase on devices using the same Apple Account."))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if purchases.isLoadingProduct {
                            ProgressView(String(localized: "Loading price…")).frame(maxWidth: .infinity)
                        } else if let product = purchases.product {
                            Button {
                                Task { await purchases.purchase() }
                            } label: {
                                VStack(spacing: 6) {
                                    Text(String(localized: "Unlock Lifetime Export — \(product.displayPrice)"))
                                    if purchases.isPurchasing { ProgressView().tint(.white) }
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .disabled(!purchases.canPurchase)
                            .accessibilityIdentifier("purchase.buy")
                        } else {
                            Button(String(localized: "Reload Price")) { Task { await purchases.loadProduct() } }
                                .buttonStyle(SecondaryActionButtonStyle())
                                .accessibilityIdentifier("purchase.reload")
                        }
                    }

                    if let message = purchases.message {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("purchase.message")
                    }

                    Button {
                        Task { await purchases.restore() }
                    } label: {
                        HStack {
                            Text(String(localized: "Restore Purchases"))
                            if purchases.isRestoring { ProgressView() }
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(purchases.isBusy)
                    .accessibilityIdentifier("purchase.restore")

                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 8) { legalLinks }
                        } else {
                            HStack(spacing: 24) { legalLinks }
                        }
                    }.font(.footnote).frame(maxWidth: .infinity)
                }
                .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .navigationTitle(String(localized: "Lifetime Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Close")) { dismiss() }.accessibilityIdentifier("purchase.close")
            } }
        }
        .tint(StudioTheme.accent)
        .task {
            await purchases.start()
            if !purchases.isUnlocked { await purchases.loadProduct() }
        }
    }

    @ViewBuilder private var legalLinks: some View {
        Link(String(localized: "Privacy Policy"), destination: AppLegalLinks.privacy)
            .frame(minHeight: 44).accessibilityIdentifier("purchase.privacy")
        Link(String(localized: "Terms of Service"), destination: AppLegalLinks.terms)
            .frame(minHeight: 44).accessibilityIdentifier("purchase.terms")
    }
}

/// Every user-content export/share sheet goes through this gate, including already-owned purchases.
struct ExportAccessGate<Content: View>: View {
    @ObservedObject var purchases: ExportPurchaseController = .shared
    @ViewBuilder var content: () -> Content
    @State private var checked = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if !checked {
                VStack(spacing: 20) {
                    ProgressView(String(localized: "Checking purchase…"))
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            } else if purchases.isUnlocked {
                content()
            } else {
                ExportPurchaseView(purchases: purchases)
            }
        }
        .task {
            await purchases.start()
            if !Task.isCancelled { checked = true }
        }
    }
}
