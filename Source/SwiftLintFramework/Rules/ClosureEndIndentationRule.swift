import Foundation
import SourceKittenFramework

public struct ClosureEndIndentationRule: Rule, OptInRule, ConfigurationProviderRule {
    public var configuration = SeverityConfiguration(.warning)

    public init() {}

    public static let description = RuleDescription(
        identifier: "closure_end_indentation",
        name: "Closure End Indentation",
        description: "Closure end should have the same indentation as the line that started it.",
        kind: .style,
        nonTriggeringExamples: ClosureEndIndentationRuleExamples.nonTriggeringExamples,
        triggeringExamples: ClosureEndIndentationRuleExamples.triggeringExamples,
        corrections: ClosureEndIndentationRuleExamples.corrections
    )

    fileprivate static let notWhitespace = regex("[^\\s]")

    public func validate(file: File) -> [StyleViolation] {
        return violations(in: file).map { violation in
            return styleViolation(for: violation, in: file)
        }
    }

    private func styleViolation(for violation: Violation, in file: File) -> StyleViolation {
        let reason = "Closure end should have the same indentation as the line that started it. " +
                     "Expected \(violation.indentationRanges.expected.length), " +
                     "got \(violation.indentationRanges.actual.length)."

        return StyleViolation(ruleDescription: type(of: self).description,
                              severity: configuration.severity,
                              location: Location(file: file, byteOffset: violation.endOffset),
                              reason: reason)
    }

}

extension ClosureEndIndentationRule: CorrectableRule {
    public func correct(file: File) -> [Correction] {
        let allViolations = violations(in: file).reversed().filter {
            !file.ruleEnabled(violatingRanges: [$0.range], for: self).isEmpty
        }

        guard !allViolations.isEmpty else {
            return []
        }

        var correctedContents = file.contents
        var correctedLocations: [Int] = []

        let actualLookup = actualViolationLookup(for: allViolations)

        for violation in allViolations {
            let expected = actualLookup(violation).indentationRanges.expected
            let actual = violation.indentationRanges.actual
            if correct(contents: &correctedContents, expected: expected, actual: actual) {
                correctedLocations.append(actual.location)
            }
        }

        var corrections = correctedLocations.map {
            return Correction(ruleDescription: type(of: self).description,
                              location: Location(file: file, characterOffset: $0))
        }

        file.write(correctedContents)

        // Re-correct to catch cascading indentation from the first round.
        corrections += correct(file: file)

        return corrections
    }

    private func correct(contents: inout String, expected: NSRange, actual: NSRange) -> Bool {
        guard let actualIndices = contents.nsrangeToIndexRange(actual) else {
            return false
        }

        let regex = ClosureEndIndentationRule.notWhitespace
        if regex.firstMatch(in: contents, options: [], range: actual) != nil {
            var correction = "\n"
            correction.append(contents.substring(from: expected.location, length: expected.length))
            contents.insert(contentsOf: correction, at: actualIndices.upperBound)
        } else {
            let correction = contents.substring(from: expected.location, length: expected.length)
            contents = contents.replacingCharacters(in: actualIndices, with: correction)
        }

        return true
    }

    private func actualViolationLookup(for violations: [Violation]) -> (Violation) -> Violation {
        let lookup = violations.reduce(into: [NSRange: Violation](), { result, violation in
            result[violation.indentationRanges.actual] = violation
        })

        func actualViolation(for violation: Violation) -> Violation {
            guard let actual = lookup[violation.indentationRanges.expected] else { return violation }
            return actualViolation(for: actual)
        }

        return actualViolation
    }
}

extension ClosureEndIndentationRule {

    fileprivate struct Violation {
        var location: Location
        var indentationRanges: (expected: NSRange, actual: NSRange)
        var endOffset: Int
        var range: NSRange
    }

    fileprivate func violations(in file: File) -> [Violation] {
        return violations(in: file, dictionary: file.structure.dictionary)
    }

    private func violations(in file: File,
                            dictionary: [String: SourceKitRepresentable]) -> [Violation] {
        return dictionary.substructure.flatMap { subDict -> [Violation] in
            var subViolations = violations(in: file, dictionary: subDict)

            if let kindString = subDict.kind,
                let kind = SwiftExpressionKind(rawValue: kindString) {
                subViolations += violations(in: file, of: kind, dictionary: subDict)
            }

            return subViolations
        }
    }

    private func violations(in file: File, of kind: SwiftExpressionKind,
                            dictionary: [String: SourceKitRepresentable]) -> [Violation] {
        guard kind == .call else {
            return []
        }

        var violations = validateArguments(in: file, dictionary: dictionary)

        if let callViolation = validateCall(in: file, dictionary: dictionary) {
            violations.append(callViolation)
        }

        return violations
    }

    private func hasTrailingClosure(in file: File,
                                    dictionary: [String: SourceKitRepresentable]) -> Bool {
        guard
            let offset = dictionary.offset,
            let length = dictionary.length,
            let text = file.contents.bridge().substringWithByteRange(start: offset, length: length)
            else {
                return false
        }

        return !text.hasSuffix(")")
    }

    private func validateCall(in file: File,
                              dictionary: [String: SourceKitRepresentable]) -> Violation? {
        let contents = file.contents.bridge()
        guard let offset = dictionary.offset,
            let length = dictionary.length,
            let bodyLength = dictionary.bodyLength,
            let nameOffset = dictionary.nameOffset,
            let nameLength = dictionary.nameLength,
            bodyLength > 0,
            case let endOffset = offset + length - 1,
            contents.substringWithByteRange(start: endOffset, length: 1) == "}",
            let startOffset = startOffset(forDictionary: dictionary, file: file),
            let (startLine, _) = contents.lineAndCharacter(forByteOffset: startOffset),
            let (endLine, endPosition) = contents.lineAndCharacter(forByteOffset: endOffset),
            case let nameEndPosition = nameOffset + nameLength,
            let (bodyOffsetLine, _) = contents.lineAndCharacter(forByteOffset: nameEndPosition),
            startLine != endLine, bodyOffsetLine != endLine,
            !containsSingleLineClosure(dictionary: dictionary, endPosition: endOffset, file: file) else {
                return nil
        }

        let range = file.lines[startLine - 1].range
        let regex = ClosureEndIndentationRule.notWhitespace
        let actual = endPosition - 1
        guard let match = regex.firstMatch(in: file.contents, options: [], range: range)?.range,
            case let expected = match.location - range.location,
            expected != actual  else {
                return nil
        }

        var expectedRange = range
        expectedRange.length = expected

        var actualRange = file.lines[endLine - 1].range
        actualRange.length = actual

        return Violation(location: Location(file: file, byteOffset: endOffset),
                         indentationRanges: (expected: expectedRange, actual: actualRange),
                         endOffset: endOffset,
                         range: NSRange(location: offset, length: length))
    }

    private func validateArguments(in file: File,
                                   dictionary: [String: SourceKitRepresentable]) -> [Violation] {
        guard isFirstArgumentOnNewline(dictionary, file: file) else {
            return []
        }

        var closureArguments = filterClosureArguments(dictionary.enclosedArguments, file: file)

        if hasTrailingClosure(in: file, dictionary: dictionary), !closureArguments.isEmpty {
            closureArguments.removeLast()
        }

        let argumentViolations = closureArguments.compactMap { dictionary in
            return validateClosureArgument(in: file, dictionary: dictionary)
        }

        return argumentViolations
    }

    private func validateClosureArgument(in file: File,
                                         dictionary: [String: SourceKitRepresentable]) -> Violation? {
        let contents = file.contents.bridge()
        guard let offset = dictionary.offset,
            let length = dictionary.length,
            let bodyLength = dictionary.bodyLength,
            let nameOffset = dictionary.nameOffset,
            let nameLength = dictionary.nameLength,
            bodyLength > 0,
            case let endOffset = offset + length - 1,
            contents.substringWithByteRange(start: endOffset, length: 1) == "}",
            let startOffset = dictionary.offset,
            let (startLine, _) = contents.lineAndCharacter(forByteOffset: startOffset),
            let (endLine, endPosition) = contents.lineAndCharacter(forByteOffset: endOffset),
            case let nameEndPosition = nameOffset + nameLength,
            let (bodyOffsetLine, _) = contents.lineAndCharacter(forByteOffset: nameEndPosition),
            startLine != endLine, bodyOffsetLine != endLine,
            !isSingleLineClosure(dictionary: dictionary, endPosition: endOffset, file: file) else {
                return nil
        }

        let range = file.lines[startLine - 1].range
        let regex = ClosureEndIndentationRule.notWhitespace
        let actual = endPosition - 1
        guard let match = regex.firstMatch(in: file.contents, options: [], range: range)?.range,
            case let expected = match.location - range.location,
            expected != actual  else {
                return nil
        }

        var expectedRange = range
        expectedRange.length = expected

        var actualRange = file.lines[endLine - 1].range
        actualRange.length = actual

        return Violation(location: Location(file: file, byteOffset: endOffset),
                         indentationRanges: (expected: expectedRange, actual: actualRange),
                         endOffset: endOffset,
                         range: NSRange(location: offset, length: length))
    }

    private func startOffset(forDictionary dictionary: [String: SourceKitRepresentable], file: File) -> Int? {
        guard let nameOffset = dictionary.nameOffset,
            let nameLength = dictionary.nameLength else {
            return nil
        }

        let newLineRegex = regex("\n(\\s*\\}?\\.)")
        let contents = file.contents.bridge()
        guard let range = contents.byteRangeToNSRange(start: nameOffset, length: nameLength),
            let match = newLineRegex.matches(in: file.contents, options: [],
                                             range: range).last?.range(at: 1),
            let methodByteRange = contents.NSRangeToByteRange(start: match.location,
                                                              length: match.length) else {
            return nameOffset
        }

        return methodByteRange.location
    }

    private func isSingleLineClosure(dictionary: [String: SourceKitRepresentable],
                                     endPosition: Int, file: File) -> Bool {
        let contents = file.contents.bridge()

        guard let start = dictionary.bodyOffset,
            let (startLine, _) = contents.lineAndCharacter(forByteOffset: start),
            let (endLine, _) = contents.lineAndCharacter(forByteOffset: endPosition) else {
                return false
        }

        return startLine == endLine
    }

    private func containsSingleLineClosure(dictionary: [String: SourceKitRepresentable],
                                           endPosition: Int, file: File) -> Bool {
        let contents = file.contents.bridge()

        guard let closure = trailingClosure(dictionary: dictionary, file: file),
            let start = closure.bodyOffset,
            let (startLine, _) = contents.lineAndCharacter(forByteOffset: start),
            let (endLine, _) = contents.lineAndCharacter(forByteOffset: endPosition) else {
                return false
        }

        return startLine == endLine
    }

    private func trailingClosure(dictionary: [String: SourceKitRepresentable],
                                 file: File) -> [String: SourceKitRepresentable]? {
        let arguments = dictionary.enclosedArguments
        let closureArguments = filterClosureArguments(arguments, file: file)

        if closureArguments.count == 1,
            closureArguments.last?.bridge() == arguments.last?.bridge() {
            return closureArguments.last
        }

        return nil
    }

    private func filterClosureArguments(_ arguments: [[String: SourceKitRepresentable]],
                                        file: File) -> [[String: SourceKitRepresentable]] {
        return arguments.filter { argument in
            guard let offset = argument.bodyOffset,
                let length = argument.bodyLength,
                let range = file.contents.bridge().byteRangeToNSRange(start: offset, length: length),
                let match = regex("\\s*\\{").firstMatch(in: file.contents, options: [], range: range)?.range,
                match.location == range.location else {
                    return false
            }

            return true
        }
    }

    private func isFirstArgumentOnNewline(_ dictionary: [String: SourceKitRepresentable],
                                          file: File) -> Bool {
        guard
            let nameOffset = dictionary.nameOffset,
            let nameLength = dictionary.nameLength,
            let firstArgument = dictionary.enclosedArguments.first,
            let firstArgumentOffset = firstArgument.offset,
            case let offset = nameOffset + nameLength,
            case let length = firstArgumentOffset - offset,
            let range = file.contents.bridge().byteRangeToNSRange(start: offset, length: length),
            let match = regex("\\(\\s*\\n\\s*").firstMatch(in: file.contents, options: [], range: range)?.range,
            match.location == range.location else {
                return false
        }

        return true
    }
}
