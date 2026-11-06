//
//  GlassUI.swift
//  ActionsRunner
//
//  Sistema Liquid Glass identico a GetMoreRam (iOS 26+ con glassEffect,
//  materiale come ripiego sui sistemi precedenti) + componenti di layout
//  costruiti con le stesse primitive.
//

import SwiftUI

/// Atmospheric graphite backdrop inspired by the app icon. It stays behind
/// content so Apple's glass surfaces can refract the background naturally.
struct AppGlassBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                LinearGradient(
                    // Near-black graphite gradient keeps the native glass
                    // readable without washing the screen into grey.
                    colors: [
                        Color(red: 0.035, green: 0.038, blue: 0.045),
                        Color(red: 0.012, green: 0.014, blue: 0.018),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color(red: 0.72, green: 0.78, blue: 0.86).opacity(0.045))
                    .frame(width: proxy.size.width * 0.78)
                    .blur(radius: 100)
                    .offset(x: proxy.size.width * 0.42, y: -proxy.size.height * 0.34)

                Circle()
                    .fill(Color.white.opacity(0.022))
                    .frame(width: proxy.size.width * 0.66)
                    .blur(radius: 90)
                    .offset(x: -proxy.size.width * 0.50, y: proxy.size.height * 0.10)

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct GlassSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.075))
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct GlassIconBadge: View {
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.40, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: size, height: size)
            .background {
                Circle().fill(Color.white.opacity(0.075))
            }
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            }
    }
}

private struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var borderOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                if #available(iOS 26.0, *) {
                    shape.fill(Color.clear).glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
    }
}

extension View {
    /// Uses real system Liquid Glass on iOS 26 and a subtle material surface on
    /// earlier systems. The shape follows the card's bounds.
    func liquidGlassCard(cornerRadius: CGFloat = 26, borderOpacity: Double = 0.14) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, borderOpacity: borderOpacity))
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                if #available(iOS 26.0, *) {
                    if prominent {
                        Capsule()
                            .fill(Color.clear)
                            .glassEffect(.regular.tint(Color.white.opacity(0.10)).interactive(), in: Capsule())
                    } else {
                        Capsule()
                            .fill(Color.clear)
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    Color.white.opacity(configuration.isPressed ? 0.30 : (prominent ? 0.22 : 0.13)),
                    lineWidth: 0.8
                )
            }
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct GlassTextFieldSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 17, borderOpacity: 0.11)
    }
}

struct GlassStatusPill: View {
    let title: String
    var symbol: String = "checkmark.circle.fill"

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(Color.white.opacity(0.075))
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
            }
    }
}

// MARK: - Componenti di layout (stesse primitive)

/// Schermata standard: sfondo graphite, scroll verticale senza indicatori, margini 18.
struct GlassScreen<Content: View>: View {
    var spacing: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AppGlassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Elenco di sistema (scorrimento per eliminare) con lo stesso aspetto di GlassScreen.
struct GlassList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AppGlassBackground()

            List {
                content
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .contentMargins(.bottom, 36, for: .scrollContent)
        }
    }
}

extension View {
    /// Riga di GlassList: senza sfondo né separatori, margini 18 come GlassScreen.
    func glassListRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 18, bottom: bottom, trailing: 18))
    }
}

extension View {
    /// Sezione principale (raggio 28, padding 18).
    func glassSection(cornerRadius: CGFloat = 28, borderOpacity: Double = 0.14) -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: cornerRadius, borderOpacity: borderOpacity)
    }

    /// Riga toccabile (raggio 22, padding 14).
    func glassRow() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .liquidGlassCard(cornerRadius: 22, borderOpacity: 0.11)
    }

    /// Riquadro interno (raggio 18, padding 14).
    func glassInset() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 18, borderOpacity: 0.10)
    }
}

/// Etichetta di campo in maiuscolo (es. "BUNDLE IDENTIFIER").
struct GlassFieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }
}

struct GlassDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
    }
}

/// Riga titolo/valore con simbolo (come detailRow delle impostazioni).
struct GlassDetailRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Scheda di apertura con il marchio dell'app.
struct GlassHeroCard: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    var markSize: CGFloat = 84

    var body: some View {
        HStack(spacing: 16) {
            Image("AppMark")
                .resizable()
                .scaledToFill()
                .frame(width: markSize, height: markSize)
                .clipShape(RoundedRectangle(cornerRadius: markSize * 0.24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: markSize * 0.24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow)
                    .font(.system(.caption, design: .rounded, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 30, borderOpacity: 0.18)
    }
}

/// Stato vuoto (cerchio con simbolo, titolo, testo).
struct GlassEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 74, height: 74)
                .background(Circle().fill(Color.white.opacity(0.055)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))

            Text(title)
                .font(.system(.headline, design: .rounded, weight: .bold))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
        .liquidGlassCard(cornerRadius: 28)
    }
}

/// Titolo di gruppo con contatore (come "Available App IDs").
struct GlassListHeader: View {
    let title: String
    var count: Int? = nil
    var symbol: String = "square.stack.3d.up.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
            Spacer()
            if let count {
                GlassStatusPill(title: "\(count)", symbol: symbol)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Chevron delle righe di navigazione.
struct GlassChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
    }
}

/// Messaggio d'errore in stile vetro.
struct GlassErrorText: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .glassInset()
    }
}
