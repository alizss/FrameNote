import FrameNoteCore
import SwiftUI

/// Comment clips sit beneath the scrubber; overlapping moments stay on separate rows.
struct FeedbackTrack: View {
    let marks: [ReviewMark]
    let duration: Double?
    let activeMark: UUID?
    var onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Feedback", systemImage: "text.bubble").font(.caption.weight(.semibold))
                Spacer()
                Text(marks.isEmpty ? "Your comments will appear here" : "Click a tag to review it")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if marks.isEmpty {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)).frame(height: 28)
            } else if let duration, duration > 0 {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                            GeometryReader { geometry in
                                let width = max(1, geometry.size.width)
                                let start = min(1, max(0, (mark.time ?? 0) / duration))
                                let end = min(1, max(start, (mark.endTime ?? mark.time ?? 0) / duration))
                                let clipWidth = min(width, max(150, (end - start) * width))
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.quaternary.opacity(0.25)).frame(height: 1)
                                    tag(mark, number: index + 1)
                                        .frame(width: clipWidth)
                                        .offset(x: min(start * width, max(0, width - clipWidth)))
                                }
                            }.frame(height: 28)
                        }
                    }
                }.frame(height: min(88, CGFloat(marks.count) * 32 - 4))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                            tag(mark, number: index + 1).frame(width: 200)
                        }
                    }
                }.frame(height: 34)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tag(_ mark: ReviewMark, number: Int) -> some View {
        Button { onSelect(mark.id) } label: {
            HStack(spacing: 6) {
                if mark.isApproved { Image(systemName: "checkmark.circle.fill") }
                Text("\(number)").fontWeight(.semibold)
                Text(mark.note.isEmpty ? "Add a comment…" : mark.note).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9).frame(height: 27)
            .foregroundStyle(mark.isApproved ? Color.green : Color.accentColor)
            .background((mark.isApproved ? Color.green : Color.accentColor).opacity(activeMark == mark.id ? 0.19 : 0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(activeMark == mark.id ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(mark.note.isEmpty ? "Open comment \(number)" : mark.note)
    }
}
