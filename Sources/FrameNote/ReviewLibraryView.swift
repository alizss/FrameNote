import SwiftUI

struct ReviewLibraryView: View {
    @ObservedObject var store: ReviewStore
    var onClose: () -> Void
    @State private var search = ""
    @State private var loading = true
    @State private var opening = false
    @State private var error: String?

    private var reviews: [SavedReview] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.savedReviews.filter { review in
            query.isEmpty || review.draft.title.localizedCaseInsensitiveContains(query) ||
                review.draft.marks.contains { $0.note.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent references").font(.title2.bold())
                    Text("Click a reference to continue. Everything saves automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back") { onClose() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search references", text: $search).textFieldStyle(.roundedBorder)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reviews.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Your references will appear here" : "No matching references",
                    systemImage: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    description: Text(search.isEmpty ? "Open a reference to start. Your work is saved automatically." : "Try another title or a word from your notes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(reviews) { review in
                            Button {
                                opening = true
                                Task {
                                    if await store.openSavedReview(review) { onClose() }
                                    else { error = store.status }
                                    opening = false
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: review.media.pathExtension == "mov" ? "film" : "photo")
                                        .font(.title2).foregroundStyle(Color.accentColor)
                                        .frame(width: 48, height: 48)
                                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(review.draft.title).font(.headline).lineLimit(2)
                                        if let date = review.draft.updatedAt {
                                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(12).contentShape(Rectangle())
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).disabled(opening)
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await store.refreshLibrary()
            if store.status.hasPrefix("Could not") { error = store.status }
            loading = false
        }
    }
}
