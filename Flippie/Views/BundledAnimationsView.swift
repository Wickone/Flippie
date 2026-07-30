import SwiftUI

struct BundledAnimationsView: View {
    let onSelectAnimation: (URL) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loadingAnimation: String?
    @State private var showingAlert = false
    @State private var alertMessage = ""

    let bundledAnimations = [
        "note_outline_music_sa_outline_to_fill_28.json ",
        "compass_music_sa_outline_to_fill_28 2.json",
        "heart_list_music_sa_outline_to_fill_28.json",
        "horse_toy_outline_music_sa_outline_to_fill_28.json",
        "podcast_books_outline_music_sa_outline_to_fill_28.json",
        "radio_outline_music_sa_outline_to_fill_28.json"
    ]

    var body: some View {
        NavigationStack {
            List(bundledAnimations, id: \.self) { animationName in
                Button {
                    loadBundledAnimation(named: animationName)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.square")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(for: animationName))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("Bundled Lottie JSON")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if loadingAnimation == animationName {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loadingAnimation != nil)
            }
            .navigationTitle("Sample Animations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .alert("Could Not Load Sample", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func loadBundledAnimation(named name: String) {
        loadingAnimation = name

        do {
            let url = try bundledURL(named: name)
            try onSelectAnimation(url)
            loadingAnimation = nil
            dismiss()
        } catch {
            loadingAnimation = nil
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    private func bundledURL(named name: String) throws -> URL {
        if let exactURL = Bundle.main.url(forResource: name, withExtension: nil) {
            return exactURL
        }

        let cleanName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".json", with: "")
        if let cleanURL = Bundle.main.url(forResource: cleanName, withExtension: "json") {
            return cleanURL
        }

        throw CocoaError(
            .fileNoSuchFile,
            userInfo: [NSLocalizedDescriptionKey: "The bundled sample “\(displayName(for: name))” is missing."]
        )
    }

    private func displayName(for fileName: String) -> String {
        fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".json", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }
}
