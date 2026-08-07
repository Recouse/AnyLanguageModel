import Foundation
import Testing

@testable import AnyLanguageModel

/// An array-of-nested-`@Generable` container: `entries` is an array whose element
/// type is itself a `@Generable` struct that references two more `@Generable`
/// types, so the schema is only valid if every definition reached transitively
/// ends up in `$defs`. The default value on `entries` is load-bearing too — it
/// exercises the type-annotation trivia that guide extraction has to tolerate.
@Generable(description: "A summary with entries")
private struct Report {
    @Generable
    struct Entry {
        let kind: EntryKind

        @Guide(description: "Payload, interpreted according to the kind")
        let payload: String

        let title: String
        let weight: Weight
    }

    @Generable
    enum EntryKind {
        @Guide(description: "A link target")
        case link

        @Guide(description: "A free-form suggestion")
        case suggestion
    }

    @Generable
    enum Weight {
        case normal, elevated
    }

    let summary: String

    @Guide(description: "Entries to display alongside the summary", .count(0 ... 3))
    var entries: [Entry] = []
}

@Generable
private struct Leaf {
    var name: String
}

@Generable
private struct NestedArrayContainer {
    var rows: [[Leaf]]
}

@Generable
private struct NestedWithOptional {
    @Generable
    struct Item {
        var name: String
        var note: String?
    }

    var items: [Item]
}

struct NestedGenerableSchemaTests {
    /// Collects every `$ref` name reachable from a node.
    private func refNames(in node: GenerationSchema.Node) -> Set<String> {
        switch node {
        case .ref(let name):
            return [name]
        case .object(let obj):
            return obj.properties.values.reduce(into: Set<String>()) { $0.formUnion(refNames(in: $1)) }
        case .array(let arr):
            return refNames(in: arr.items)
        case .anyOf(let nodes):
            return nodes.reduce(into: Set<String>()) { $0.formUnion(refNames(in: $1)) }
        case .string, .number, .boolean:
            return []
        }
    }

    private func assertAllRefsDefined(_ schema: GenerationSchema, sourceLocation: SourceLocation = #_sourceLocation) {
        var pending = refNames(in: schema.root)
        var visited: Set<String> = []

        while let name = pending.popFirst() {
            guard !visited.contains(name) else { continue }
            visited.insert(name)

            guard let def = schema.defs[name] else {
                Issue.record(
                    "Missing $defs entry for '\(name)'. Defined: \(schema.defs.keys.sorted())",
                    sourceLocation: sourceLocation
                )
                continue
            }
            pending.formUnion(refNames(in: def))
        }
    }

    @Test func arrayOfGenerableElementsCarriesElementDefs() throws {
        let schema = [Report.Entry].generationSchema

        guard case .array(let arrayNode) = schema.root else {
            Issue.record("Expected array root, got \(schema.root)")
            return
        }
        guard case .ref(let elementName) = arrayNode.items else {
            Issue.record("Expected element $ref, got \(arrayNode.items)")
            return
        }

        #expect(schema.defs[elementName] != nil)
        assertAllRefsDefined(schema)
    }

    @Test func propertyHoldingArrayOfGenerablesKeepsDefs() throws {
        assertAllRefsDefined(Report.generationSchema)
    }

    @Test func nestedArrayOfArraysKeepsDefs() throws {
        assertAllRefsDefined(NestedArrayContainer.generationSchema)
    }

    @Test func encodedSchemaContainsDefsForArrayElements() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(Report.generationSchema)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try #require(json["$defs"] as? [String: Any])

        #expect(defs[String(reflecting: Report.Entry.self)] != nil)
        #expect(defs[String(reflecting: Report.EntryKind.self)] != nil)
        #expect(defs[String(reflecting: Report.Weight.self)] != nil)
    }

    @Test func countGuideSurvivesDefaultValueOnProperty() throws {
        guard case .object(let root)? = Report.generationSchema.withResolvedRoot()?.root else {
            Issue.record("Expected a resolvable object root")
            return
        }
        guard case .array(let entries)? = root.properties["entries"] else {
            Issue.record("Expected 'entries' to be an array node")
            return
        }

        #expect(entries.minItems == 0)
        #expect(entries.maxItems == 3)
    }

    // MARK: - OpenAI strict mode

    /// Every `$ref` in the strict-mode payload must resolve against its `$defs`.
    @Test func strictModeSchemaResolvesEveryRef() throws {
        let value = try Report.generationSchema.toJSONValueForOpenAIStrictMode()
        guard case .object(let root) = value else {
            Issue.record("Expected object schema")
            return
        }
        guard case .object(let defs)? = root["$defs"] else {
            Issue.record("Expected $defs, got keys \(root.keys.sorted())")
            return
        }

        for name in collectRefNames(in: value) {
            #expect(defs[name] != nil, "Unresolved $ref '\(name)'; defined: \(defs.keys.sorted())")
        }
    }

    /// Strict mode rejects any object whose optional properties are absent from
    /// `required` — including objects nested inside `$defs`.
    @Test func strictModeMarksNestedOptionalPropertiesRequired() throws {
        let value = try NestedWithOptional.generationSchema.toJSONValueForOpenAIStrictMode()

        for (path, object) in collectObjectSchemas(in: value, path: "#") {
            guard case .object(let properties)? = object["properties"], !properties.isEmpty else { continue }

            guard case .array(let required)? = object["required"] else {
                Issue.record("\(path) is missing 'required'")
                continue
            }
            let requiredNames = Set(
                required.compactMap { value -> String? in
                    guard case .string(let name) = value else { return nil }
                    return name
                }
            )
            #expect(requiredNames == Set(properties.keys), "\(path) has incomplete 'required'")
            #expect(object["additionalProperties"] == .bool(false), "\(path) allows additional properties")
        }
    }

    /// A property literally named "properties" must not be treated as schema structure.
    @Test func strictModeDoesNotConfusePropertyNamedProperties() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "properties": .object(["type": .string("string")]),
                "items": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("properties")]),
        ])

        let normalized = GenerationSchema.applyOpenAIStrictMode(to: schema)
        guard case .object(let root) = normalized,
            case .object(let properties)? = root["properties"]
        else {
            Issue.record("Expected object schema")
            return
        }

        // The inner "properties"/"items" entries are plain string schemas and must
        // be left untouched.
        #expect(properties["properties"] == .object(["type": .string("string")]))
        #expect(properties["items"] == .object(["type": .string("string")]))
        #expect(root["required"] == .array([.string("items"), .string("properties")]))
    }

    // MARK: - Helpers

    private func collectRefNames(in value: JSONValue) -> Set<String> {
        switch value {
        case .object(let obj):
            var names: Set<String> = []
            if case .string(let ref)? = obj["$ref"] {
                names.insert(ref.replacingOccurrences(of: "#/$defs/", with: ""))
            }
            for nested in obj.values {
                names.formUnion(collectRefNames(in: nested))
            }
            return names
        case .array(let items):
            return items.reduce(into: Set<String>()) { $0.formUnion(collectRefNames(in: $1)) }
        default:
            return []
        }
    }

    private func collectObjectSchemas(
        in value: JSONValue,
        path: String
    ) -> [(String, [String: JSONValue])] {
        guard case .object(let obj) = value else { return [] }

        var found: [(String, [String: JSONValue])] = []
        if case .string("object")? = obj["type"] {
            found.append((path, obj))
        }

        if case .object(let properties)? = obj["properties"] {
            for (name, nested) in properties {
                found += collectObjectSchemas(in: nested, path: "\(path)/properties/\(name)")
            }
        }
        if case .object(let defs)? = obj["$defs"] {
            for (name, nested) in defs {
                found += collectObjectSchemas(in: nested, path: "\(path)/$defs/\(name)")
            }
        }
        if let items = obj["items"] {
            found += collectObjectSchemas(in: items, path: "\(path)/items")
        }
        if case .array(let choices)? = obj["anyOf"] {
            for (index, nested) in choices.enumerated() {
                found += collectObjectSchemas(in: nested, path: "\(path)/anyOf/\(index)")
            }
        }
        return found
    }
}
