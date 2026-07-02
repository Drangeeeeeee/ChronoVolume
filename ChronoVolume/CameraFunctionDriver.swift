import Foundation

struct CameraFunctionDriverState: Equatable, Codable {
    var isEnabled: Bool = false
    var yawExpression: String = ""
    var pitchExpression: String = ""
    var rollExpression: String = ""
    var distanceExpression: String = ""
    var positionXExpression: String = ""
    var positionYExpression: String = ""
    var positionZExpression: String = ""
    var focalLengthExpression: String = ""
    var apertureExpression: String = ""

    var hasAnyExpression: Bool {
        [yawExpression, pitchExpression, rollExpression, positionXExpression, positionYExpression, positionZExpression, focalLengthExpression, apertureExpression]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum CameraExpressionEvaluator {
    static func evaluate(_ expression: String, x: Double, y: Double) -> Double? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parser = Parser(input: trimmed, x: x, y: y)
        return try? parser.parse()
    }
}

private struct Parser {
    let scalars: [UnicodeScalar]
    let x: Double
    let y: Double
    var index: Int = 0

    init(input: String, x: Double, y: Double) {
        self.scalars = Array(input.unicodeScalars)
        self.x = x
        self.y = y
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        skipSpaces()
        guard index == scalars.count else { throw ParseError.invalid }
        return value
    }

    mutating private func parseExpression() throws -> Double {
        var value = try parseTerm()
        while true {
            skipSpaces()
            if consume("+") {
                value += try parseTerm()
            } else if consume("-") {
                value -= try parseTerm()
            } else {
                return value
            }
        }
    }

    mutating private func parseTerm() throws -> Double {
        var value = try parsePower()
        while true {
            skipSpaces()
            if consume("*") {
                value *= try parsePower()
            } else if consume("/") {
                let rhs = try parsePower()
                guard abs(rhs) > .ulpOfOne else { throw ParseError.invalid }
                value /= rhs
            } else {
                return value
            }
        }
    }

    mutating private func parsePower() throws -> Double {
        var value = try parseUnary()
        skipSpaces()
        if consume("^") {
            value = pow(value, try parsePower())
        }
        return value
    }

    mutating private func parseUnary() throws -> Double {
        skipSpaces()
        if consume("+") { return try parseUnary() }
        if consume("-") { return -(try parseUnary()) }
        return try parsePrimary()
    }

    mutating private func parsePrimary() throws -> Double {
        skipSpaces()
        if consume("(") {
            let value = try parseExpression()
            guard consume(")") else { throw ParseError.invalid }
            return value
        }

        if let number = parseNumber() {
            return number
        }

        let identifier = parseIdentifier()
        guard !identifier.isEmpty else { throw ParseError.invalid }
        switch identifier.lowercased() {
        case "x", "t", "progress":
            return x
        case "y", "base":
            return y
        case "pi":
            return Double.pi
        default:
            guard consume("(") else { throw ParseError.invalid }
            let first = try parseExpression()
            skipSpaces()
            let result: Double
            if consume(",") {
                let second = try parseExpression()
                guard consume(")") else { throw ParseError.invalid }
                result = try applyBinary(identifier, first, second)
            } else {
                guard consume(")") else { throw ParseError.invalid }
                result = try applyUnary(identifier, first)
            }
            return result
        }
    }

    mutating private func parseNumber() -> Double? {
        skipSpaces()
        let start = index
        var sawDigit = false
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.decimalDigits.contains(scalar) {
                sawDigit = true
                index += 1
            } else if scalar == "." {
                index += 1
            } else {
                break
            }
        }
        if index < scalars.count && (scalars[index] == "e" || scalars[index] == "E") {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                index += 1
            }
            while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
                sawDigit = true
                index += 1
            }
        }
        guard sawDigit else {
            index = start
            return nil
        }
        return Double(String(String.UnicodeScalarView(scalars[start..<index])))
    }

    mutating private func parseIdentifier() -> String {
        skipSpaces()
        let start = index
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "_" {
                index += 1
            } else {
                break
            }
        }
        return String(String.UnicodeScalarView(scalars[start..<index]))
    }

    mutating private func consume(_ scalar: UnicodeScalar) -> Bool {
        skipSpaces()
        guard index < scalars.count, scalars[index] == scalar else { return false }
        index += 1
        return true
    }

    mutating private func skipSpaces() {
        while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
            index += 1
        }
    }

    private func applyUnary(_ name: String, _ value: Double) throws -> Double {
        switch name.lowercased() {
        case "sin": return sin(value)
        case "cos": return cos(value)
        case "tan": return tan(value)
        case "abs": return abs(value)
        case "sqrt": return sqrt(max(0, value))
        case "floor": return floor(value)
        case "ceil": return ceil(value)
        case "round": return round(value)
        case "log": return log(value)
        case "exp": return exp(value)
        default: throw ParseError.invalid
        }
    }

    private func applyBinary(_ name: String, _ a: Double, _ b: Double) throws -> Double {
        switch name.lowercased() {
        case "pow": return pow(a, b)
        case "min": return min(a, b)
        case "max": return max(a, b)
        default: throw ParseError.invalid
        }
    }

    private enum ParseError: Error {
        case invalid
    }
}
