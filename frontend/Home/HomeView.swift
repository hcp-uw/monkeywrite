import SwiftUI

enum Theme {
    static let background = Color(red: 21 / 255, green: 22 / 255, blue: 23 / 255)
    static let surface = Color(red: 0.12, green: 0.13, blue: 0.15)
    static let accent = Color(red: 1, green: 198 / 255, blue: 65 / 255)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.89)
    static let secondary = Color(red: 0.66, green: 0.68, blue: 0.71)
}

struct HomeView: View {
    @AppStorage(SettingsStorage.modeKey) private var mode = TestMode.oneMinute
    @AppStorage("singlePlayer.subject") private var subject = PassageSubject.biology
    @State private var showsSubjects = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 36) {
                        branding

                        VStack(spacing: 18) {
                            if geometry.size.width >= 600 && !dynamicTypeSize.isAccessibilitySize {
                                HStack(alignment: .top, spacing: 28) {
                                    modeBox
                                        .frame(maxWidth: .infinity)
                                    subjectBox
                                        .frame(width: 210)
                                }
                            } else {
                                VStack(spacing: 16) {
                                    modeBox
                                    subjectBox
                                }
                            }

                            NavigationLink {
                                SinglePlayerView(
                                    model: RoundModel(passageSource: BundledPassages(subject: subject))
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Text("Start Round")
                                    Image(systemName: "arrow.right")
                                        .accessibilityHidden(true)
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .foregroundStyle(Theme.background)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                                .contentShape(RoundedRectangle(cornerRadius: 18))
                            }
                            .frame(maxWidth: 380)
                            .buttonStyle(.plain)
                            .accessibilityHint("Starts \(mode.title) with a \(subject.title) passage")
                        }
                        .frame(maxWidth: 600)
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 48)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var branding: some View {
        VStack(spacing: 12) {
            Image("MonkeyWriteWordmark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 480)
                .accessibilityLabel("MonkeyWrite")
                .accessibilityAddTraits(.isHeader)

            Text("Put your handwriting speed and accuracy to the test.")
                .font(.title3.weight(.regular))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mode")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 2) {
                ForEach(TestMode.choices, id: \.self) { choice in
                    Button { mode = choice } label: {
                        HStack(spacing: 6) {
                            Image(systemName: choice.symbol)
                                .accessibilityHidden(true)
                            Text(choice.title)
                                .monospacedDigit()
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .opacity(mode == choice ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(mode == choice ? Theme.background : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 6)
                        .background(mode == choice ? Theme.accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(mode == choice ? .isSelected : [])
                    .accessibilityHint(choice.description)
                }
            }
            .padding(3)
            .background(Theme.surface, in: Capsule())

            Text(mode.description)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.secondary.opacity(0.2), lineWidth: 1)
        }
        .foregroundStyle(Theme.text)
    }

    private var subjectBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subject")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Button {
                showsSubjects.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(subject.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subject, \(subject.title)")
            .accessibilityHint("Choose Biology, History, or Computer Science")
            .popover(isPresented: $showsSubjects, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PassageSubject.allCases) { choice in
                        Button {
                            subject = choice
                            showsSubjects = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(choice.title)
                                Spacer()
                                Image(systemName: "checkmark")
                                    .opacity(subject == choice ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .font(.body)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 210, minHeight: 44)
                            .background(
                                subject == choice ? Theme.secondary.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(subject == choice ? .isSelected : [])
                    }
                }
                .padding(8)
                .foregroundStyle(Theme.text)
                .presentationBackground(Color(red: 0.23, green: 0.24, blue: 0.27))
                .presentationCompactAdaptation(.popover)
                .preferredColorScheme(.dark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.secondary.opacity(0.2), lineWidth: 1)
        }
        .foregroundStyle(Theme.text)
    }
}

#Preview("Home") {
    HomeView()
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
}
