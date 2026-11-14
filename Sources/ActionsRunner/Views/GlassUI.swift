//
//  GlassUI.swift
//  ActionsRunner
//
//  Sistema Liquid Glass identico a GetMoreRam (iOS 26+ con glassEffect,
//  materiale come ripiego sui sistemi precedenti) + componenti di layout
//  costruiti con le stesse primitive.
//

import SwiftUI
import UIKit

extension Color {
    /// Inchiostro del vetro: bianco con l'aspetto scuro, nero con quello chiaro.
    static let glassInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .black })
    /// Linee e riempimenti del vetro (bordi, cerchi): bianco nello scuro, nero attenuato nel chiaro.
    static let glassLine = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0, alpha: 0.55) })
    /// Ombra delle schede: più leggera nell'aspetto chiaro.
    static let glassShadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.18) : UIColor(white: 0, alpha: 0.07) })
}

/// Atmospheric graphite backdrop inspired by the app icon. It stays behind
/// content so Apple's glass surfaces can refract the background naturally.
struct AppGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            Group {
                if colorScheme == .dark {
                    darkBackdrop(proxy)
                } else {
                    lightBackdrop(proxy)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // sfondo statico: rasterizzato in un'unica texture invece di ricomporre i livelli
        // a ogni fotogramma (push/pop della navigazione, scorrimento)
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Aspetto scuro originale (graphite quasi nero).
    private func darkBackdrop(_ proxy: GeometryProxy) -> some View {
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

            SoftGlow(color: Color(red: 0.72, green: 0.78, blue: 0.86).opacity(0.045),
                     diameter: proxy.size.width * 0.78, blur: 100)
                .offset(x: proxy.size.width * 0.42, y: -proxy.size.height * 0.34)

            SoftGlow(color: Color.white.opacity(0.022), diameter: proxy.size.width * 0.66, blur: 90)
                .offset(x: -proxy.size.width * 0.50, y: proxy.size.height * 0.10)

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }

    /// Aspetto chiaro: porcellana grigio-azzurra con gli stessi riflessi sfocati.
    private func lightBackdrop(_ proxy: GeometryProxy) -> some View {
        ZStack {
            Color(red: 0.955, green: 0.960, blue: 0.970)

            LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.988, blue: 0.995),
                    Color(red: 0.940, green: 0.947, blue: 0.960),
                    Color(red: 0.905, green: 0.915, blue: 0.932)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            SoftGlow(color: Color(red: 0.62, green: 0.70, blue: 0.84).opacity(0.22),
                     diameter: proxy.size.width * 0.78, blur: 100)
                .offset(x: proxy.size.width * 0.42, y: -proxy.size.height * 0.34)

            SoftGlow(color: Color.white.opacity(0.70), diameter: proxy.size.width * 0.66, blur: 90)
                .offset(x: -proxy.size.width * 0.50, y: proxy.size.height * 0.10)

            LinearGradient(
                colors: [.clear, Color(red: 0.86, green: 0.875, blue: 0.90).opacity(0.70)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

/// Alone morbido: stesso aspetto di un cerchio sfocato (`blur`), ma disegnato con un
/// gradiente radiale, che non richiede il costoso filtro di sfocatura gaussiana.
private struct SoftGlow: View {
    let color: Color
    let diameter: CGFloat
    let blur: CGFloat

    var body: some View {
        let r = diameter / 2
        let outer = r + blur * 1.4
        // l'ingombro resta quello del cerchio originale; l'alone sborda come faceva la sfocatura
        Color.clear
            .frame(width: diameter, height: diameter)
            .overlay {
                RadialGradient(
                    stops: [
                        .init(color: color, location: 0),
                        .init(color: color, location: max(0, (r - blur) / outer)),
                        .init(color: color.opacity(0.5), location: r / outer),
                        .init(color: color.opacity(0), location: 1),
                    ],
                    center: .center, startRadius: 0, endRadius: outer
                )
                .frame(width: outer * 2, height: outer * 2)
            }
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
                    .foregroundStyle(Color.glassInk.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .background {
                        Circle()
                            .fill(Color.glassLine.opacity(0.075))
                    }
                    .overlay {
                        Circle().strokeBorder(Color.glassLine.opacity(0.14), lineWidth: 0.8)
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
            .foregroundStyle(Color.glassInk.opacity(0.95))
            .frame(width: size, height: size)
            .background {
                Circle().fill(Color.glassLine.opacity(0.075))
            }
            .overlay {
                Circle().strokeBorder(Color.glassLine.opacity(0.16), lineWidth: 0.8)
            }
    }
}

private struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var borderOpacity: Double
    var shadow: Bool

    func body(content: Content) -> some View {
        if shadow {
            card(content).shadow(color: Color.glassShadow, radius: 18, x: 0, y: 9)
        } else {
            card(content)
        }
    }

    private func card(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                if #available(iOS 26.0, *) {
                    shape.fill(Color.clear).glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(Color.glassLine.opacity(borderOpacity), lineWidth: 0.8)
            }
    }
}

extension View {
    /// Uses real system Liquid Glass on iOS 26 and a subtle material surface on
    /// earlier systems. The shape follows the card's bounds.
    /// `shadow: false` per righe ripetute e riquadri interni: l'ombra sfocata di ogni elemento
    /// va calcolata fuori schermo ed è la causa principale di scatti durante lo scorrimento.
    func liquidGlassCard(cornerRadius: CGFloat = 26, borderOpacity: Double = 0.14, shadow: Bool = true) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, borderOpacity: borderOpacity, shadow: shadow))
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                if #available(iOS 26.0, *) {
                    if prominent {
                        Capsule()
                            .fill(Color.clear)
                            .glassEffect(.regular.tint(Color.glassLine.opacity(0.10)).interactive(), in: Capsule())
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
                    Color.glassLine.opacity(configuration.isPressed ? 0.30 : (prominent ? 0.22 : 0.13)),
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
            .liquidGlassCard(cornerRadius: 17, borderOpacity: 0.11, shadow: false)
    }
}

struct GlassStatusPill: View {
    let title: String
    var symbol: String = "checkmark.circle.fill"

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(Color.glassInk.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(Color.glassLine.opacity(0.075))
            }
            .overlay {
                Capsule().strokeBorder(Color.glassLine.opacity(0.12), lineWidth: 0.7)
            }
    }
}

// MARK: - Aspetto (Sistema / Chiaro / Scuro)

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Applicato alle finestre (vale anche per fogli e avvisi; con "Sistema" segue subito l'iPhone).
    @MainActor
    static func apply(_ appearance: AppAppearance) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = appearance.interfaceStyle
            }
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
            .liquidGlassCard(cornerRadius: 22, borderOpacity: 0.11, shadow: false)
    }

    /// Riquadro interno (raggio 18, padding 14).
    func glassInset() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 18, borderOpacity: 0.10, shadow: false)
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
        Rectangle().fill(Color.glassLine.opacity(0.10)).frame(height: 1)
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
                        .strokeBorder(Color.glassLine.opacity(0.20), lineWidth: 0.8)
                }
                .shadow(color: Color.glassShadow, radius: 12, x: 0, y: 6)

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
                .background(Circle().fill(Color.glassLine.opacity(0.055)))
                .overlay(Circle().strokeBorder(Color.glassLine.opacity(0.12), lineWidth: 0.8))

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
