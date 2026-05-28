import Foundation

// A deliberately small Gherkin parser — just enough of the grammar to run the
// vendored typedb-behaviour feature files. It supports Feature, Background,
// Scenario, Scenario Outline + Examples, doc strings (""" ... """), single- and
// multi-column data tables, comments, tags, and the trailing `; fails` /
// `; parsing fails` step suffix the suite uses to assert expected errors.

/// Whether a step is expected to succeed, fail, or fail at parse time.
enum FailureExpectation: Equatable {
    case none
    case fails
    case parsingFails
}

/// A single Given/When/Then/And/But step.
struct GherkinStep {
    let keyword: String          // Given / When / Then / And / But (informational only)
    let text: String             // step text with the `; fails` suffix stripped
    let failure: FailureExpectation
    let docString: String?       // triple-quoted block attached to this step
    let dataTable: [[String]]    // rows of trimmed cells; empty if no table
}

/// A concrete scenario (outlines are expanded into one of these per Examples row).
struct GherkinScenario {
    let name: String
    let tags: [String]
    let steps: [GherkinStep]
}

/// A parsed feature file.
struct GherkinFeature {
    let name: String
    let background: [GherkinStep]
    let scenarios: [GherkinScenario]
}

enum GherkinParser {
    private static let stepKeywords = ["Given", "When", "Then", "And", "But", "*"]

    static func parse(_ source: String) -> GherkinFeature {
        // Strip comments and trailing whitespace, keep blank lines for doc strings.
        let rawLines = source.components(separatedBy: "\n")
        var featureName = ""
        var background: [GherkinStep] = []
        var scenarios: [GherkinScenario] = []

        // Parsing state for the current scenario / outline.
        var pendingTags: [String] = []
        var currentName = ""
        var currentTags: [String] = []
        var currentSteps: [GherkinStep] = []
        var isOutline = false
        var inBackground = false
        var haveCurrent = false
        var examples: [[String: String]] = []
        var collectingExamples = false
        var exampleHeader: [String] = []

        func flush() {
            guard haveCurrent || inBackground else { return }
            if inBackground {
                background = currentSteps
            } else if isOutline {
                // Expand the outline across its Examples rows.
                if examples.isEmpty {
                    scenarios.append(GherkinScenario(name: currentName, tags: currentTags, steps: currentSteps))
                } else {
                    for row in examples {
                        let expanded = currentSteps.map { substitute($0, with: row) }
                        let suffix = row.sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                        scenarios.append(GherkinScenario(
                            name: "\(currentName) [\(suffix)]",
                            tags: currentTags,
                            steps: expanded))
                    }
                }
            } else {
                scenarios.append(GherkinScenario(name: currentName, tags: currentTags, steps: currentSteps))
            }
            currentSteps = []
            examples = []
            exampleHeader = []
            collectingExamples = false
            isOutline = false
            inBackground = false
            haveCurrent = false
        }

        var i = 0
        while i < rawLines.count {
            let line = rawLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments at structural level.
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            if trimmed.hasPrefix("@") {
                pendingTags.append(contentsOf: trimmed.split(separator: " ").map(String.init))
                i += 1
                continue
            }

            if trimmed.hasPrefix("Feature:") {
                featureName = value(after: "Feature:", in: trimmed)
                pendingTags = []
                i += 1
                continue
            }

            if trimmed.hasPrefix("Background:") {
                flush()
                inBackground = true
                haveCurrent = true
                currentName = "Background"
                currentTags = []
                pendingTags = []
                i += 1
                continue
            }

            if trimmed.hasPrefix("Scenario Outline:") || trimmed.hasPrefix("Scenario:") {
                flush()
                isOutline = trimmed.hasPrefix("Scenario Outline:")
                let marker = isOutline ? "Scenario Outline:" : "Scenario:"
                currentName = value(after: marker, in: trimmed)
                currentTags = pendingTags
                pendingTags = []
                haveCurrent = true
                i += 1
                continue
            }

            if trimmed.hasPrefix("Examples:") {
                collectingExamples = true
                exampleHeader = []
                i += 1
                continue
            }

            // Data-table / examples rows.
            if trimmed.hasPrefix("|") {
                let cells = tableCells(trimmed)
                if collectingExamples {
                    if exampleHeader.isEmpty {
                        exampleHeader = cells
                    } else {
                        var row: [String: String] = [:]
                        for (idx, key) in exampleHeader.enumerated() where idx < cells.count {
                            row[key] = cells[idx]
                        }
                        examples.append(row)
                    }
                } else if var last = currentSteps.popLast() {
                    // Attach to the most recent step.
                    var table = last.dataTable
                    table.append(cells)
                    last = GherkinStep(keyword: last.keyword, text: last.text,
                                       failure: last.failure, docString: last.docString,
                                       dataTable: table)
                    currentSteps.append(last)
                }
                i += 1
                continue
            }

            // Step lines.
            if let keyword = stepKeyword(of: trimmed) {
                let body = String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
                let (text, failure) = splitFailure(body)

                // Look ahead for an attached doc string.
                var docString: String? = nil
                var j = i + 1
                while j < rawLines.count {
                    let peek = rawLines[j].trimmingCharacters(in: .whitespaces)
                    if peek.isEmpty || peek.hasPrefix("#") { j += 1; continue }
                    break
                }
                if j < rawLines.count {
                    let peek = rawLines[j].trimmingCharacters(in: .whitespaces)
                    if peek == "\"\"\"" {
                        var docLines: [String] = []
                        // Indentation of the opening fence, to dedent the body.
                        let fenceIndent = indentation(of: rawLines[j])
                        var k = j + 1
                        while k < rawLines.count {
                            let docLine = rawLines[k]
                            if docLine.trimmingCharacters(in: .whitespaces) == "\"\"\"" { break }
                            docLines.append(dedent(docLine, by: fenceIndent))
                            k += 1
                        }
                        docString = docLines.joined(separator: "\n")
                        i = k + 1
                        currentSteps.append(GherkinStep(keyword: keyword, text: text,
                                                        failure: failure, docString: docString,
                                                        dataTable: []))
                        continue
                    }
                }

                currentSteps.append(GherkinStep(keyword: keyword, text: text,
                                                failure: failure, docString: docString,
                                                dataTable: []))
                i += 1
                continue
            }

            i += 1
        }

        flush()
        return GherkinFeature(name: featureName, background: background, scenarios: scenarios)
    }

    // MARK: - Helpers

    private static func stepKeyword(of line: String) -> String? {
        for kw in stepKeywords where line == kw || line.hasPrefix(kw + " ") {
            return kw
        }
        return nil
    }

    private static func value(after marker: String, in line: String) -> String {
        String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func splitFailure(_ body: String) -> (String, FailureExpectation) {
        let t = body.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("; parsing fails") {
            return (String(t.dropLast("; parsing fails".count)).trimmingCharacters(in: .whitespaces), .parsingFails)
        }
        if t.hasSuffix("; fails") {
            return (String(t.dropLast("; fails".count)).trimmingCharacters(in: .whitespaces), .fails)
        }
        return (t, .none)
    }

    private static func tableCells(_ line: String) -> [String] {
        // "| a | b |" -> ["a", "b"]
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // Drop the empty leading/trailing fragments produced by the outer pipes.
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func substitute(_ step: GherkinStep, with row: [String: String]) -> GherkinStep {
        func sub(_ s: String) -> String {
            var out = s
            for (key, value) in row {
                out = out.replacingOccurrences(of: "<\(key)>", with: value)
            }
            return out
        }
        let table = step.dataTable.map { $0.map(sub) }
        return GherkinStep(keyword: step.keyword, text: sub(step.text), failure: step.failure,
                           docString: step.docString.map(sub), dataTable: table)
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func dedent(_ line: String, by count: Int) -> String {
        var n = count
        var out = Substring(line)
        while n > 0, out.first == " " { out = out.dropFirst(); n -= 1 }
        return String(out)
    }
}
