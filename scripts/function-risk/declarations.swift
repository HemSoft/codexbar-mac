import Foundation
import SwiftParser
import SwiftSyntax

// Use the SwiftSyntax shipped with the selected Xcode, not a floating package.
struct Declaration: Encodable {
    let path: String
    let symbol: String
    let kind: String
    let line: Int
    let bodyLine: Int
    let endLine: Int
    let lintLine: Int
    let lintColumn: Int
}

final class Inventory: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    var declarations: [Declaration] = []

    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func scope(_ node: some SyntaxProtocol) -> String {
        var names: [String] = []
        var parent = node.parent
        while let current = parent {
            if let type = current.as(StructDeclSyntax.self) { names.append(type.name.text) }
            if let type = current.as(ClassDeclSyntax.self) { names.append(type.name.text) }
            if let type = current.as(EnumDeclSyntax.self) { names.append(type.name.text) }
            if let type = current.as(ActorDeclSyntax.self) { names.append(type.name.text) }
            if let type = current.as(ExtensionDeclSyntax.self) {
                names.append(type.extendedType.trimmedDescription)
            }
            if let function = current.as(FunctionDeclSyntax.self) {
                names.append(function.name.text + function.signature.trimmedDescription)
            }
            parent = current.parent
        }
        return names.reversed().joined(separator: ".")
    }

    private func record(
        _ node: some SyntaxProtocol, body: CodeBlockSyntax, token: TokenSyntax, kind: String
    ) {
        let start = node.positionAfterSkippingLeadingTrivia
        let signature = node.tokens(viewMode: .sourceAccurate)
            .prefix { $0.positionAfterSkippingLeadingTrivia < body.leftBrace.positionAfterSkippingLeadingTrivia }
            .map(\.text).joined(separator: " ")
        let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        declarations.append(Declaration(
            path: path, symbol: scope(node) + "." + signature, kind: kind,
            line: converter.location(for: start).line,
            bodyLine: converter.location(for: body.leftBrace.positionAfterSkippingLeadingTrivia).line,
            endLine: converter.location(for: body.rightBrace.positionAfterSkippingLeadingTrivia).line,
            lintLine: location.line, lintColumn: location.column
        ))
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            let token = node.modifiers.first {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }?.name ?? node.funcKeyword
            record(node, body: body, token: token, kind: "function")
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body { record(node, body: body, token: node.initKeyword, kind: "initializer") }
        return .visitChildren
    }
}

var output: [Declaration] = []
for path in CommandLine.arguments.dropFirst().sorted() {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let tree = Parser.parse(source: source)
    guard !tree.hasError else { fatalError("Cannot parse \(path)") }
    let inventory = Inventory(path: path, tree: tree)
    inventory.walk(tree)
    output += inventory.declarations
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
FileHandle.standardOutput.write(try encoder.encode(output))
