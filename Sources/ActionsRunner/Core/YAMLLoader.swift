import Foundation

/// Punto d'ingresso per il caricamento YAML (parser nativo in YAMLParser.swift).
enum YAMLLoader {
    static func load(_ text: String) throws -> JSONValue {
        try YAMLParser.parse(text)
    }
}
