//
//  Interpreter.swift
//  ShapeScript
//
//  Created by Nick Lockwood on 26/09/2018.
//  Copyright © 2018 Nick Lockwood. All rights reserved.
//

import Euclid
import Foundation

// MARK: Public interface

public protocol EvaluationDelegate: AnyObject {
    func resolveURL(for path: String) -> URL
    func importGeometry(for url: URL) throws -> Geometry?
    func debugLog(_ values: [AnyHashable])
}

public func evaluate(
    _ program: Program,
    delegate: EvaluationDelegate?,
    cache: GeometryCache? = GeometryCache(),
    isCancelled: @escaping () -> Bool = { false }
) throws -> Scene {
    let context = EvaluationContext(
        source: program.source,
        delegate: delegate,
        isCancelled: isCancelled
    )
    try program.evaluate(in: context)
    return Scene(
        background: context.background,
        children: context.children.compactMap { $0.value as? Geometry },
        cache: cache
    )
}

public enum ImportError: Error, Equatable {
    case lexerError(LexerError)
    case parserError(ParserError)
    case runtimeError(RuntimeError)
    case unknownError

    public init(_ error: Error) {
        switch error {
        case let error as LexerError: self = .lexerError(error)
        case let error as ParserError: self = .parserError(error)
        case let error as RuntimeError: self = .runtimeError(error)
        default: self = .unknownError
        }
    }

    public var message: String {
        switch self {
        case let .lexerError(error): return error.message
        case let .parserError(error): return error.message
        case let .runtimeError(error): return error.message
        default: return "Unknown error"
        }
    }

    public var range: SourceRange {
        switch self {
        case let .lexerError(error): return error.range
        case let .parserError(error): return error.range
        case let .runtimeError(error): return error.range
        default: return "".startIndex ..< "".endIndex
        }
    }

    public var hint: String? {
        switch self {
        case let .lexerError(error): return error.hint
        case let .parserError(error): return error.hint
        case let .runtimeError(error): return error.hint
        default: return nil
        }
    }
}

public enum RuntimeErrorType: Error, Equatable {
    case unknownSymbol(String, options: [String])
    case unknownMember(String, of: String, options: [String])
    case unknownFont(String, options: [String])
    case typeMismatch(for: String, index: Int, expected: String, got: String)
    case unexpectedArgument(for: String, max: Int)
    case missingArgument(for: String, index: Int, type: String)
    case unusedValue(type: String)
    case assertionFailure(String)
    case fileNotFound(for: String, at: URL?)
    case fileAccessRestricted(for: String, at: URL)
    case fileTypeMismatch(for: String, at: URL, expected: String?)
    case fileParsingError(for: String, at: URL, message: String)
    indirect case importError(ImportError, for: String, in: String)
}

public struct RuntimeError: Error, Equatable {
    public let type: RuntimeErrorType
    public let range: SourceRange

    public init(_ type: RuntimeErrorType, at range: SourceRange) {
        self.type = type
        self.range = range
    }
}

public extension RuntimeError {
    var message: String {
        switch type {
        case let .unknownSymbol(name, _):
            if Keyword(rawValue: name) == nil, Symbols.all[name] == nil {
                return "Unknown symbol '\(name)'"
            }
            return "Unexpected symbol '\(name)'"
        case let .unknownMember(name, type, _):
            return "Unknown \(type) member property '\(name)'"
        case let .unknownFont(name, _):
            return "Unknown font '\(name)'"
        case .typeMismatch:
            return "Type mismatch"
        case .unexpectedArgument:
            return "Unexpected argument"
        case .missingArgument:
            return "Missing argument"
        case .unusedValue:
            return "Unused value"
        case .assertionFailure:
            return "Assertion failure"
        case let .fileNotFound(for: name, _):
            guard !name.isEmpty else {
                return "Empty file name"
            }
            return "File '\(name)' not found"
        case let .fileAccessRestricted(for: name, _):
            return "Unable to access file '\(name)'"
        case let .fileParsingError(for: name, _, _),
             let .fileTypeMismatch(for: name, _, _):
            return "Unable to open file '\(name)'"
        case let .importError(error, for: name, _):
            if case let .runtimeError(error) = error, case .importError = error.type {
                return error.message
            }
            return "Error in imported file '\(name)': \(error.message)"
        }
    }

    var suggestion: String? {
        switch type {
        case let .unknownSymbol(name, options), let .unknownMember(name, _, options):
            return Self.alternatives[name.lowercased()]?
                .first(where: { options.contains($0) || Keyword(rawValue: $0) != nil })
                ?? bestMatches(for: name, in: options).first
        case let .unknownFont(name, options):
            return bestMatches(for: name, in: options).first
        default:
            return nil
        }
    }

    var hint: String? {
        func nth(_ index: Int) -> String {
            switch index {
            case 1 ..< String.ordinals.count:
                return "\(String.ordinals[index]) "
            default:
                return ""
            }
        }
        func formatMessage(_ message: String) -> String? {
            guard let last = message.last else {
                return nil
            }
            if ".?!".contains(last) {
                return message
            }
            return "\(message)."
        }
        switch type {
        case let .unknownSymbol(name, _):
            var hint = Keyword(rawValue: name) == nil && Symbols.all[name] == nil ? "" :
                "The \(name) command is not available in this context."
            if let suggestion = suggestion {
                hint = (hint.isEmpty ? "" : "\(hint) ") + "Did you mean '\(suggestion)'?"
            }
            return hint
        case .unknownMember:
            return suggestion.map { "Did you mean '\($0)'?" }
        case .unknownFont:
            if let suggestion = suggestion {
                return "Did you mean '\(suggestion)'?"
            }
            return ""
        case let .typeMismatch(for: name, index: index, expected: type, got: got):
            let got = got.contains(",") ? got : "a \(got)"
            return "The \(nth(index))argument for \(name) should be a \(type), not \(got)."
        case let .unexpectedArgument(for: name, max: max):
            if max == 0 {
                return "The \(name) command does not expect any arguments."
            } else if max == 1 {
                return "The \(name) command expects only a single argument."
            } else {
                return "The \(name) command expects a maximum of \(max) arguments."
            }
        case let .missingArgument(for: name, index: index, type: type):
            let type = (type == ValueType.pair.errorDescription) ? ValueType.number.errorDescription : type
            if index == 0 {
                return "The \(name) command expects an argument of type \(type)."
            } else {
                return "The \(name) command expects a \(nth(index))argument of type \(type)."
            }
        case let .unusedValue(type: type):
            return "A \(type) value was not expected in this context."
        case let .assertionFailure(message):
            return formatMessage(message)
        case let .fileNotFound(for: _, at: url):
            guard let url = url else {
                return nil
            }
            return "ShapeScript expected to find the file at '\(url.path)'. Check that it exists and is located here."
        case let .fileAccessRestricted(for: _, at: url):
            return "ShapeScript cannot read the file due to macOS security restrictions. Please open the directory at '\(url.path)' to grant access."
        case let .fileParsingError(for: _, at: _, message: message):
            return formatMessage(message)
        case let .fileTypeMismatch(for: _, at: url, expected: type):
            guard let type = type else {
                return "The type of file at '\(url.path)' is not supported."
            }
            return "The file at '\(url.path)' is not a \(type) file."
        case let .importError(error, for: _, in: _):
            return error.hint
        }
    }

    static func wrap<T>(_ fn: @autoclosure () throws -> T, at range: SourceRange) throws -> T {
        do {
            return try fn()
        } catch let error as RuntimeErrorType {
            throw RuntimeError(error, at: range)
        }
    }
}

// MARK: Implementation

private struct EvaluationCancelled: Error {}

private extension RuntimeError {
    static let alternatives = [
        "box": ["cube"],
        "rect": ["square"],
        "rectangle": ["square"],
        "ellipse": ["circle"],
        "elipse": ["circle"],
        "squircle": ["roundrect"],
        "rotate": ["orientation"],
        "rotation": ["orientation"],
        "orientation": ["rotate"],
        "translate": ["position"],
        "translation": ["position"],
        "position": ["translate"],
        "scale": ["size"],
        "size": ["scale"],
        "width": ["size", "x"],
        "height": ["size", "y"],
        "depth": ["size", "z"],
        "length": ["size"],
        "radius": ["size"],
        "x": ["width", "position"],
        "y": ["height", "position"],
        "z": ["depth", "position"],
        "option": ["define"],
        "subtract": ["difference"],
        "subtraction": ["difference"],
    ]

    // Find best match for a given string in a list of options
    func bestMatches(for query: String, in options: [String]) -> [String] {
        let lowercaseQuery = query.lowercased()
        // Sort matches by Levenshtein edit distance
        return options
            .compactMap { option -> (String, distance: Int, commonPrefix: Int)? in
                let lowercaseOption = option.lowercased()
                let distance = editDistance(lowercaseOption, lowercaseQuery)
                let commonPrefix = lowercaseOption.commonPrefix(with: lowercaseQuery)
                if commonPrefix.isEmpty, distance > lowercaseQuery.count / 2 {
                    return nil
                }
                return (option, distance, commonPrefix.count)
            }
            .sorted {
                if $0.distance == $1.distance {
                    return $0.commonPrefix > $1.commonPrefix
                }
                return $0.distance < $1.distance
            }
            .map { $0.0 }
    }

    /// The Damerau-Levenshtein edit-distance between two strings
    func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs)
        let rhs = Array(rhs)
        var dist = [[Int]]()
        for i in 0 ... lhs.count {
            dist.append([i])
        }
        for j in 1 ... rhs.count {
            dist[0].append(j)
        }
        for i in 1 ... lhs.count {
            for j in 1 ... rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    dist[i].append(dist[i - 1][j - 1])
                } else {
                    dist[i].append(min(dist[i - 1][j] + 1,
                                       dist[i][j - 1] + 1,
                                       dist[i - 1][j - 1] + 1))
                }
                if i > 1, j > 1, lhs[i - 1] == rhs[j - 2], lhs[i - 2] == rhs[j - 1] {
                    dist[i][j] = min(dist[i][j], dist[i - 2][j - 2] + 1)
                }
            }
        }
        return dist[lhs.count][rhs.count]
    }
}

enum ValueType {
    case color
    case texture
    case colorOrTexture // Hack to support either types
    case font
    case number
    case vector
    case size
    case string
    case path
    case paths // Hack to support multiple paths
    case mesh
    case tuple
    case point
    case pair // Hack to support common math functions
    case range
    case void
}

private extension ValueType {
    var errorDescription: String {
        switch self {
        case .color: return "color"
        case .texture: return "texture"
        case .colorOrTexture: return "color or texture"
        case .font: return "font"
        case .number: return "number"
        case .vector: return "vector"
        case .size: return "size"
        case .string: return "string"
        case .path: return "path"
        case .paths: return "path"
        case .mesh: return "mesh"
        case .tuple: return "tuple"
        case .point: return "point"
        case .pair: return "pair"
        case .range: return "range"
        case .void: return "void"
        }
    }
}

enum Value {
    case color(Color)
    case texture(Texture?)
    case number(Double)
    case vector(Vector)
    case size(Vector)
    case string(String?) // TODO: handle optionals in a better way than this
    case path(Path)
    case mesh(Geometry)
    case point(PathPoint)
    case tuple([Value])
    case range(RangeValue)

    static let void: Value = .tuple([])

    static func colorOrTexture(_ value: MaterialProperty) -> Value {
        switch value {
        case let .color(color):
            return .color(color)
        case let .texture(texture):
            return .texture(texture)
        }
    }

    var value: AnyHashable {
        switch self {
        case let .color(color): return color
        case let .texture(texture):
            return texture.map { $0 as AnyHashable } ?? texture as AnyHashable
        case let .number(number): return number
        case let .vector(vector): return vector
        case let .size(size): return size
        case let .string(string):
            return string.map { $0 as AnyHashable } ?? string as AnyHashable
        case let .path(path): return path
        case let .mesh(mesh): return mesh
        case let .point(point): return point
        case let .tuple(values): return values.map { $0.value }
        case let .range(range): return range
        }
    }

    var doubleValue: Double {
        assert(value is Double)
        return value as? Double ?? 0
    }

    var intValue: Int {
        Int(truncating: doubleValue as NSNumber)
    }

    var type: ValueType {
        switch self {
        case .color: return .color
        case .texture: return .texture
        case .number: return .number
        case .vector: return .vector
        case .size: return .size
        case .string: return .string
        case .path: return .path
        case .mesh: return .mesh
        case .point: return .point
        case .tuple: return .tuple
        case .range: return .range
        }
    }

    var members: [String] {
        switch self {
        case .vector:
            return ["x", "y", "z"]
        case .size:
            return ["width", "height", "depth"]
        case .color:
            return ["red", "green", "blue", "alpha"]
        case let .tuple(values):
            var members = Array(String.ordinals(upTo: values.count))
            guard values.allSatisfy({ $0.type == .number }) else {
                if values.count == 1 {
                    members += values[0].members
                }
                return members
            }
            if values.count < 5 {
                members += ["red", "green", "blue", "alpha"]
                if values.count < 4 {
                    members += ["x", "y", "z", "width", "height", "depth"]
                }
            }
            return members
        case .range:
            return ["start", "end", "step"]
        case .texture, .number, .string, .path, .mesh, .point:
            return []
        }
    }

    subscript(_ name: String) -> Value? {
        switch self {
        case let .vector(vector):
            switch name {
            case "x": return .number(vector.x)
            case "y": return .number(vector.y)
            case "z": return .number(vector.z)
            default: return nil
            }
        case let .size(size):
            switch name {
            case "width": return .number(size.x)
            case "height": return .number(size.y)
            case "depth": return .number(size.z)
            default: return nil
            }
        case let .color(color):
            switch name {
            case "red": return .number(color.r)
            case "green": return .number(color.g)
            case "blue": return .number(color.b)
            case "alpha": return .number(color.a)
            default: return nil
            }
        case let .tuple(values):
            if let index = name.ordinalIndex {
                return index < values.count ? values[index] : nil
            }
            guard values.allSatisfy({ $0.type == .number }) else {
                if values.count == 1 {
                    return values[0][name]
                }
                return nil
            }
            let values = values.map { $0.value as? Double ?? 0 }
            switch name {
            case "x", "y", "z":
                return values.count < 4 ? Value.vector(Vector(values))[name] : nil
            case "width", "height", "depth":
                return values.count < 4 ? Value.size(Vector(size: values))[name] : nil
            case "red", "green", "blue", "alpha":
                return values.count < 5 ? Value.color(Color(unchecked: values))[name] : nil
            default:
                return nil
            }
        case let .range(range):
            switch name {
            case "start": return .number(range.start)
            case "end": return .number(range.end)
            case "step": return .number(range.step)
            default: return nil
            }
        case .texture, .number, .string, .path, .mesh, .point:
            return nil
        }
    }
}

struct RangeValue: Hashable, Sequence {
    var start, end, step: Double

    init(from start: Double, to end: Double) {
        self.init(from: start, to: end, step: 1)!
    }

    init?(from start: Double, to end: Double, step: Double) {
        guard step != 0 else {
            return nil
        }
        self.start = start
        self.end = end
        self.step = step
    }

    func makeIterator() -> StrideThrough<Double>.Iterator {
        stride(from: start, through: end, by: step).makeIterator()
    }
}

typealias Options = [String: ValueType]

enum BlockType {
    case builder
    case group
    case path
    case text
    indirect case custom(BlockType?, Options)

    static let primitive = BlockType.custom(nil, [:])

    var options: Options {
        switch self {
        case let .custom(baseType, options):
            return (baseType?.options ?? [:]).merging(options) { $1 }
        case .builder, .group, .path, .text:
            return [:]
        }
    }

    var childTypes: Set<ValueType> {
        switch self {
        case .builder: return [.path]
        case .group: return [.mesh]
        case .path: return [.point, .path]
        case .text: return [.string]
        case let .custom(baseType, _):
            return baseType?.childTypes ?? []
        }
    }

    var symbols: Symbols {
        switch self {
        case .group: return .group
        case .builder: return .builder
        case .path: return .path
        case .text: return .text
        case let .custom(baseType, _):
            return baseType?.symbols ?? .primitive
        }
    }
}

extension Program {
    func evaluate(in context: EvaluationContext) throws {
        let oldSource = context.source
        context.source = source
        do {
            try statements.forEach { try $0.evaluate(in: context) }
        } catch is EvaluationCancelled {}
        context.source = oldSource
    }
}

private func evaluateParameters(
    _ parameters: [Expression],
    in context: EvaluationContext
) throws -> [Value] {
    var values = [Value]()
    loop: for (i, param) in parameters.enumerated() {
        if i < parameters.count - 1, case let .identifier(identifier) = param.type {
            let (name, range) = (identifier.name, identifier.range)
            switch context.symbol(for: name) {
            case let .command(parameterType, fn)? where parameterType != .void:
                let range = parameters[i + 1].range.lowerBound ..< parameters.last!.range.upperBound
                let param = Expression(type: .tuple(Array(parameters[(i + 1)...])), range: range)
                let arg = try evaluateParameter(param, as: parameterType, for: identifier, in: context)
                try RuntimeError.wrap(values.append(fn(arg, context)), at: range)
                break loop
            case let .block(type, fn) where !type.childTypes.isEmpty:
                let childContext = context.push(type)
                for parameter in parameters[(i + 1)...] {
                    let child = try parameter.evaluate(in: context)
                    // TODO: find better solution
                    let children: [Value]
                    if case let .tuple(values) = child {
                        children = values
                    } else {
                        children = [child]
                    }
                    for child in children {
                        do {
                            try childContext.addValue(child)
                        } catch {
                            throw RuntimeError(
                                .typeMismatch(
                                    for: identifier.name,
                                    index: 0,
                                    expected: "block",
                                    got: child.type.errorDescription
                                ),
                                at: parameter.range
                            )
                        }
                    }
                }
                try RuntimeError.wrap(values.append(fn(childContext)), at: range)
                break loop
            default:
                break
            }
        }
        try values.append(param.evaluate(in: context))
    }
    return values
}

// TODO: find a better way to encapsulate this
private func evaluateParameter(_ parameter: Expression?,
                               as type: ValueType,
                               for identifier: Identifier,
                               in context: EvaluationContext) throws -> Value
{
    let (name, range) = (identifier.name, identifier.range)
    guard let parameter = parameter else {
        if type == .void {
            return .void
        }
        throw RuntimeError(
            .missingArgument(for: name, index: 0, type: type.errorDescription),
            at: range.upperBound ..< range.upperBound
        )
    }
    return try parameter.evaluate(as: type, for: identifier.name, in: context)
}

extension Definition {
    func evaluate(in context: EvaluationContext) throws -> Symbol {
        switch type {
        case let .expression(expression):
            let context = context.pushDefinition()
            let value = try expression.evaluate(in: context)
            switch value {
            case .tuple:
                return .constant(value)
            default:
                // Wrap all definitions as a single-value tuple
                // so that ordinal access and looping will work
                return .constant(.tuple([value]))
            }
        case let .block(block):
            var options = Options()
            for statement in block.statements {
                if case let .option(identifier, expression) = statement.type {
                    let value = try expression.evaluate(in: context) // TODO: get static type w/o evaluating
                    options[identifier.name] = value.type
                }
            }
            let source = context.source
            let baseURL = context.baseURL
            return .block(.custom(nil, options)) { _context in
                do {
                    let context = context.pushDefinition()
                    context.stackDepth = _context.stackDepth + 1
                    if context.stackDepth > 25 {
                        throw RuntimeErrorType.assertionFailure("Too much recursion")
                    }
                    for (name, symbol) in _context.userSymbols {
                        context.define(name, as: symbol)
                    }
                    context.children += _context.children
                    context.name = _context.name
                    context.transform = _context.transform
                    context.opacity = _context.opacity
                    context.detail = _context.detail
                    for statement in block.statements {
                        if case let .option(identifier, expression) = statement.type {
                            if context.symbol(for: identifier.name) == nil {
                                context.define(identifier.name,
                                               as: .constant(try expression.evaluate(in: context)))
                            }
                        } else {
                            try statement.evaluate(in: context)
                        }
                    }
                    let children = context.children
                    if children.count == 1, let value = children.first {
                        guard let path = value.value as? Path else {
                            let geometry = value.value as! Geometry
                            return .mesh(Geometry(
                                type: geometry.type,
                                name: context.name,
                                transform: geometry.transform * context.transform,
                                material: geometry.material,
                                children: geometry.children,
                                sourceLocation: context.sourceLocation
                            ))
                        }
                        if let name = context.name {
                            return .mesh(Geometry(
                                type: .path(path),
                                name: name,
                                transform: context.transform,
                                material: .default,
                                children: [],
                                sourceLocation: context.sourceLocation
                            ))
                        }
                        return .path(path.transformed(by: context.transform))
                    } else if context.name == nil, !children.isEmpty, !children.contains(where: {
                        if case .path = $0 { return false } else { return true }
                    }) {
                        return .tuple(children.map {
                            .path(($0.value as! Path).transformed(by: context.transform))
                        })
                    }
                    return .mesh(Geometry(
                        type: .group,
                        name: context.name,
                        transform: context.transform,
                        material: .default,
                        children: children.map {
                            guard let path = $0.value as? Path else {
                                return $0.value as! Geometry
                            }
                            return Geometry(
                                type: .path(path),
                                name: nil,
                                transform: .identity,
                                material: .default,
                                children: [],
                                sourceLocation: context.sourceLocation
                            )
                        },
                        sourceLocation: context.sourceLocation
                    ))
                } catch {
                    if baseURL == context.baseURL {
                        throw error
                    }
                    // TODO: improve this error by mentioning the symbol that failed
                    // and showing the context of the failure not just the call site
                    throw RuntimeErrorType.importError(
                        ImportError(error),
                        for: baseURL?.lastPathComponent ?? "",
                        in: source
                    )
                }
            }
        }
    }
}

extension EvaluationContext {
    func addValue(_ value: Value) throws {
        switch value {
        case _ where childTypes.contains(value.type):
            switch value {
            case let .mesh(m):
                children.append(.mesh(m.transformed(by: childTransform)))
            case let .vector(v):
                children.append(.vector(v.transformed(by: childTransform)))
            case let .point(v):
                children.append(.point(v.transformed(by: childTransform)))
            case let .path(path):
                children.append(.path(path.transformed(by: childTransform)))
            default:
                children.append(value)
            }
        case let .path(path) where childTypes.contains(.mesh):
            children.append(.mesh(Geometry(
                type: .path(path),
                name: name,
                transform: childTransform,
                material: .default, // not used for paths
                children: [],
                sourceLocation: sourceLocation
            )))
        case let .tuple(values):
            try values.forEach(addValue)
        default:
            throw RuntimeErrorType.unusedValue(type: value.type.errorDescription)
        }
    }
}

extension Statement {
    func evaluate(in context: EvaluationContext) throws {
        switch type {
        case let .command(identifier, parameter):
            let (name, range) = (identifier.name, identifier.range)
            guard let symbol = context.symbol(for: name) else {
                throw RuntimeError(
                    .unknownSymbol(name, options: context.commandSymbols),
                    at: range
                )
            }
            switch symbol {
            case let .command(type, fn):
                let argument = try evaluateParameter(parameter,
                                                     as: type,
                                                     for: identifier,
                                                     in: context)
                try RuntimeError.wrap(context.addValue(fn(argument, context)), at: range)
            case let .property(type, setter, _):
                let argument = try evaluateParameter(parameter,
                                                     as: type,
                                                     for: identifier,
                                                     in: context)
                try RuntimeError.wrap(setter(argument, context), at: range)
            case let .block(type, fn):
                context.sourceIndex = range.lowerBound
                if let parameter = parameter {
                    func unwrap(_ value: Value) -> Value {
                        if case let .tuple(values) = value {
                            if values.count == 1 {
                                return unwrap(values[0])
                            }
                            return .tuple(values.map(unwrap))
                        } else {
                            return value
                        }
                    }
                    let child = try unwrap(parameter.evaluate(in: context))
                    // TODO: find better solution
                    let children: [Value]
                    if case let .tuple(values) = child {
                        children = values
                    } else {
                        children = [child]
                    }
                    guard children.allSatisfy({ type.childTypes.contains($0.type) }) else {
                        // TODO: return valid child types instead of just "block"
                        throw RuntimeError(
                            .typeMismatch(
                                for: name,
                                index: 0,
                                expected: "block",
                                got: child.type.errorDescription
                            ),
                            at: parameter.range
                        )
                    }
                    try RuntimeError.wrap({
                        let childContext = context.push(type)
                        childContext.userSymbols.removeAll()
                        try children.forEach(childContext.addValue)
                        try context.addValue(fn(childContext))
                    }(), at: range)
                } else if !type.childTypes.isEmpty {
                    throw RuntimeError(
                        .missingArgument(for: name, index: 0, type: "block"),
                        at: range
                    )
                } else {
                    let childContext = context.push(type)
                    childContext.userSymbols.removeAll()
                    try RuntimeError.wrap(context.addValue(fn(childContext)), at: range)
                }
            case let .constant(v):
                try RuntimeError.wrap(context.addValue(v), at: range)
            }
        case let .block(identifier, block):
            // TODO: better solution
            // This only works correctly if node was not imported from another file
            context.sourceIndex = range.lowerBound
            let expression = Expression(type: .block(identifier, block), range: range)
            try RuntimeError.wrap(context.addValue(expression.evaluate(in: context)), at: range)
        case let .expression(expression):
            try RuntimeError.wrap(context.addValue(expression.evaluate(in: context)), at: range)
        case let .define(identifier, definition):
            context.define(identifier.name, as: try definition.evaluate(in: context))
        case .option:
            throw RuntimeError(.unknownSymbol("option", options: []), at: range)
        case let .forloop(identifier, in: expression, block):
            let range = try expression.evaluate(in: context)
            let sequence: AnySequence<Value>
            switch range {
            case let .range(range):
                sequence = AnySequence(range.lazy.map { .number($0) })
            case let .tuple(values):
                // TODO: find less hacky way to do this unwrap
                if values.count == 1, case let .range(range) = values[0] {
                    sequence = AnySequence(range.lazy.map { .number($0) })
                } else {
                    sequence = AnySequence(values)
                }
            case .vector, .size, .color, .texture, .number, .string, .path, .mesh, .point:
                throw RuntimeError(
                    .typeMismatch(
                        for: "range",
                        index: 0,
                        expected: "range or tuple",
                        got: range.type.errorDescription
                    ),
                    at: expression.range
                )
            }
            for value in sequence {
                if context.isCancelled() {
                    throw EvaluationCancelled()
                }
                try context.pushScope { context in
                    if let name = identifier?.name {
                        context.define(name, as: .constant(value))
                    }
                    for statement in block.statements {
                        try statement.evaluate(in: context)
                    }
                }
            }
        case let .import(expression):
            let pathValue = try expression.evaluate(in: context)
            guard let path = pathValue.value as? String else {
                let got = (pathValue.type == .string) ? "nil" : pathValue.type.errorDescription
                throw RuntimeError(
                    .typeMismatch(
                        for: Keyword.import.rawValue, index: 0,
                        expected: ValueType.string.errorDescription, got: got
                    ),
                    at: expression.range
                )
            }
            context.sourceIndex = expression.range.lowerBound
            try RuntimeError.wrap(context.importModel(at: path), at: expression.range)
        }
    }
}

extension Expression {
    func evaluate(in context: EvaluationContext) throws -> Value {
        switch type {
        case let .number(number):
            return .number(number)
        case let .string(string):
            return .string(string)
        case let .color(color):
            return .color(color)
        case let .identifier(identifier):
            let (name, range) = (identifier.name, identifier.range)
            guard let symbol = context.symbol(for: name) else {
                throw RuntimeError(
                    .unknownSymbol(name, options: context.expressionSymbols),
                    at: range
                )
            }
            switch symbol {
            case let .command(parameterType, fn):
                guard parameterType == .void else {
                    // Commands with parameters can't be used in expressions without parens
                    // TODO: allow this if child matches next argument
                    throw RuntimeError(.missingArgument(
                        for: name,
                        index: 0,
                        type: parameterType.errorDescription
                    ), at: range.upperBound ..< range.upperBound)
                }
                return try RuntimeError.wrap(fn(.void, context), at: range)
            case let .property(_, _, getter):
                return try RuntimeError.wrap(getter(context), at: range)
            case let .block(type, fn):
                guard type.childTypes.isEmpty else {
                    // Blocks that require children can't be used in expressions without parens
                    // TODO: allow this if child matches next argument
                    throw RuntimeError(.missingArgument(
                        for: name,
                        index: 0,
                        type: "block"
                    ), at: range.upperBound ..< range.upperBound)
                }
                return try RuntimeError.wrap(fn(context.push(type)), at: range)
            case let .constant(value):
                return value
            }
        case let .block(identifier, block):
            let (name, range) = (identifier.name, identifier.range)
            guard let symbol = context.symbol(for: name) else {
                throw RuntimeError(.unknownSymbol(name, options: context.expressionSymbols), at: range)
            }
            switch symbol {
            case let .block(type, fn):
                if context.isCancelled() {
                    throw EvaluationCancelled()
                }
                let sourceIndex = context.sourceIndex
                let context = context.push(type)
                for statement in block.statements {
                    switch statement.type {
                    case let .command(identifier, parameter):
                        let name = identifier.name
                        guard let type = type.options[name] else {
                            fallthrough
                        }
                        context.define(name, as: try .constant(
                            evaluateParameter(parameter,
                                              as: type,
                                              for: identifier,
                                              in: context)
                        ))
                    case .block, .define, .forloop, .expression, .import:
                        try statement.evaluate(in: context)
                    case .option:
                        throw RuntimeError(.unknownSymbol("option", options: []), at: statement.range)
                    }
                }
                context.sourceIndex = sourceIndex
                return try RuntimeError.wrap(fn(context), at: range)
            case let .command(type, _):
                throw RuntimeError(
                    .typeMismatch(for: name, index: 0, expected: type.errorDescription, got: "block"),
                    at: block.range
                )
            case .property, .constant:
                throw RuntimeError(
                    .unexpectedArgument(for: name, max: 0),
                    at: block.range
                )
            }
        case let .tuple(expressions):
            return try .tuple(evaluateParameters(expressions, in: context))
        case let .prefix(op, expression):
            let value = try expression.evaluate(as: .number, for: String(op.rawValue), index: 0, in: context)
            switch op {
            case .minus:
                return .number(-value.doubleValue)
            case .plus:
                return .number(value.doubleValue)
            }
        case let .infix(lhs, op, rhs):
            let lhs = try lhs.evaluate(as: .number, for: String(op.rawValue), index: 0, in: context)
            let rhs = try rhs.evaluate(as: .number, for: String(op.rawValue), index: 1, in: context)
            switch op {
            case .minus:
                return .number(lhs.doubleValue - rhs.doubleValue)
            case .plus:
                return .number(lhs.doubleValue + rhs.doubleValue)
            case .times:
                return .number(lhs.doubleValue * rhs.doubleValue)
            case .divide:
                return .number(lhs.doubleValue / rhs.doubleValue)
            }
        case let .range(from: start, to: end, step: step):
            let start = try start.evaluate(as: .number, for: "start value", in: context)
            let end = try end.evaluate(as: .number, for: "end value", in: context)
            guard let stepParam = step else {
                return .range(RangeValue(from: start.doubleValue, to: end.doubleValue))
            }
            let step = try stepParam.evaluate(as: .number, for: "step value", in: context)
            guard let value = RangeValue(
                from: start.doubleValue,
                to: end.doubleValue,
                step: step.doubleValue
            ) else {
                throw RuntimeError(
                    .assertionFailure("Step value must be nonzero"),
                    at: stepParam.range
                )
            }
            return .range(value)
        case let .member(expression, member):
            var value = try expression.evaluate(in: context)
            if let memberValue = value[member.name] {
                assert(value.members.contains(member.name),
                       "\(value.type.errorDescription) does not have member '\(member.name)'")
                return memberValue
            }
            // TODO: find less hacky way to do this unwrap
            if case let .tuple(values) = value, values.count == 1 {
                value = values[0]
            }
            throw RuntimeError(.unknownMember(
                member.name,
                of: value.type.errorDescription,
                options: value.members
            ), at: member.range)
        case let .subexpression(expression):
            return try expression.evaluate(in: context)
        }
    }

    func evaluate(as type: ValueType, for name: String, index: Int = 0, in context: EvaluationContext) throws -> Value {
        var parameters = [self]
        if case let .tuple(expressions) = self.type {
            parameters = expressions
        }
        func unwrap(_ value: Value) -> Value {
            if case let .tuple(values) = value {
                if values.count == 1 {
                    return unwrap(values[0])
                }
                return .tuple(values.map(unwrap))
            } else {
                return value
            }
        }
        let values = try evaluateParameters(parameters, in: context).map(unwrap)
        assert(values.count <= parameters.count)
        func numerify(max: Int, min: Int) throws -> [Double] {
            if parameters.count > max {
                throw RuntimeError(.unexpectedArgument(for: name, max: max), at: parameters[max].range)
            } else if parameters.count < min {
                let upperBound = parameters.last?.range.upperBound ?? range.upperBound
                throw RuntimeError(
                    .missingArgument(for: name, index: min - 1, type: ValueType.number.errorDescription),
                    at: upperBound ..< upperBound
                )
            }
            var values = values
            if values.count == 1, case let .tuple(elements) = values[0] {
                if elements.count > max {
                    let range: SourceRange
                    if case let .tuple(expressions) = parameters[0].type {
                        range = expressions[max].range
                    } else {
                        range = parameters[0].range
                    }
                    throw RuntimeError(.unexpectedArgument(for: name, max: max), at: range)
                }
                values = elements
            }
            if values.count > 1, values[0].type == type ||
                ((values[0].value as? [Any])?.allSatisfy { $0 is Double } == true)
            {
                if parameters.count > 1 {
                    throw RuntimeError(
                        .unexpectedArgument(for: name, max: 1),
                        at: parameters[1].range
                    )
                }
                let types = [type.errorDescription] + values.dropFirst().map { $0.type.errorDescription }
                throw RuntimeError(.typeMismatch(
                    for: name,
                    index: index,
                    expected: type.errorDescription,
                    got: types.joined(separator: ", ")
                ), at: range)
            }
            var numbers = [Double]()
            for (i, value) in values.enumerated() {
                guard case let .number(number) = value else {
                    // TODO: this seems like a hack - what's the actual solution?
                    let i = Swift.min(parameters.count - 1, i)
                    let type = (i == 0 ? type : .number).errorDescription
                    throw RuntimeError(
                        .typeMismatch(
                            for: name,
                            index: index + i,
                            expected: type,
                            got: value.type.errorDescription
                        ),
                        at: parameters[i].range
                    )
                }
                numbers.append(number)
            }
            return numbers
        }
        if parameters.isEmpty {
            // TODO: can this actually happen?
            if type != .void {
                throw RuntimeError(.missingArgument(
                    for: name,
                    index: index,
                    type: type.errorDescription
                ), at: range)
            }
            return .void
        }
        if values.count == 1, values[0].type == type {
            return values[0]
        }
        switch type {
        case .color:
            let numbers = try numerify(max: 4, min: 1)
            return .color(Color(unchecked: numbers))
        case .vector:
            let numbers = try numerify(max: 3, min: 1)
            return .vector(Vector(numbers))
        case .size:
            let numbers = try numerify(max: 3, min: 1)
            return .size(Vector(size: numbers))
        case .pair:
            let numbers = try numerify(max: 2, min: 2)
            return .tuple(numbers.map { .number($0) })
        case .tuple:
            return .tuple(values)
        case .texture where values.count == 1 && values[0].type == .string:
            let name = values[0].value as? String
            return try RuntimeError.wrap(.texture(name.map {
                .file(name: $0, url: try context.resolveURL(for: $0))
            }), at: parameters[0].range)
        case .colorOrTexture:
            switch values[0] {
            case .string, .texture:
                return try evaluate(as: .texture, for: name, in: context)
            default:
                return try evaluate(as: .color, for: name, in: context)
            }
        case .font where values.count == 1 && values[0].type == .string:
            let name = values[0].value as? String
            return try RuntimeError.wrap(.string(validateFont(name)), at: parameters[0].range)
        case .paths:
            return try .tuple(values.enumerated().flatMap { i, value -> [Value] in
                switch value {
                case .path:
                    return [value]
                case let .tuple(values):
                    guard values.allSatisfy({ $0.type == .path }) else {
                        throw RuntimeError(
                            .typeMismatch(
                                for: name,
                                index: index + i,
                                expected: ValueType.path.errorDescription,
                                got: value.type.errorDescription
                            ),
                            at: parameters[i].range
                        )
                    }
                    return values
                default:
                    throw RuntimeError(
                        .typeMismatch(
                            for: name,
                            index: index + i,
                            expected: ValueType.path.errorDescription,
                            got: value.type.errorDescription
                        ),
                        at: parameters[i].range
                    )
                }
            })
        case .number, .string, .texture, .font, .path, .mesh, .point, .range:
            if values.count > 1, parameters.count > 1 {
                throw RuntimeError(
                    .unexpectedArgument(for: name, max: 1),
                    at: parameters[1].range
                )
            }
            let value = values[0]
            if value.type != type {
                throw RuntimeError(
                    .typeMismatch(
                        for: name,
                        index: index,
                        expected: type.errorDescription,
                        got: value.type.errorDescription
                    ),
                    at: parameters[0].range
                )
            }
            throw RuntimeError(
                .typeMismatch(
                    for: name,
                    index: index,
                    expected: type.errorDescription,
                    got: values[0].type.errorDescription
                ),
                at: parameters[0].range
            )
        case .void:
            throw RuntimeError(
                .unexpectedArgument(for: name, max: 0),
                at: parameters[0].range
            )
        }
    }
}

private func validateFont(_ name: String?) throws -> String? {
    guard let name = name?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "  ", with: " ")
    else {
        return nil
    }
    #if canImport(CoreGraphics)
    guard CGFont(name as CFString) != nil else {
        var options = [String]()
        #if canImport(CoreText)
        options += CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        options += CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        #endif
        throw RuntimeErrorType.unknownFont(name, options: options)
    }
    #endif
    return name
}
