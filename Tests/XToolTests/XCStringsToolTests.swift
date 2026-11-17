import Foundation
import Testing
@testable import XToolSupport

struct XCStringsToolTests {
    @Test func compilesPlainStrings() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "Hello": {
              "localizations": {
                "ko": { "stringUnit": { "state": "translated", "value": "안녕하세요" } }
              }
            },
            "greeting": {
              "localizations": {
                "en": { "stringUnit": { "state": "translated", "value": "Hi \\"there\\"\\n" } },
                "ko": { "stringUnit": { "state": "needs_review", "value": "안녕" } }
              }
            },
            "Brand": {
              "shouldTranslate": false,
              "localizations": {
                "ko": { "stringUnit": { "state": "translated", "value": "ignored" } }
              }
            }
          },
          "version": "1.0"
        }
        """)
        #expect(outputs.keys.sorted() == ["en.lproj/Localizable.strings", "ko.lproj/Localizable.strings"])
        #expect(try strings(outputs["en.lproj/Localizable.strings"]) == [
            "Hello": "Hello",
            "greeting": "Hi \"there\"\n",
            "Brand": "Brand",
        ])
        #expect(try strings(outputs["ko.lproj/Localizable.strings"]) == [
            "Hello": "안녕하세요",
            "greeting": "안녕",
        ])
    }

    @Test func restrictsLanguages() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "Hello": {
              "localizations": {
                "de": { "stringUnit": { "state": "translated", "value": "Hallo" } },
                "ko": { "stringUnit": { "state": "translated", "value": "안녕" } }
              }
            }
          }
        }
        """, languages: ["ko"])
        #expect(outputs.keys.sorted() == ["ko.lproj/Localizable.strings"])
    }

    @Test func compilesPluralVariations() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "%@ has %lld items": {
              "localizations": {
                "en": {
                  "variations": {
                    "plural": {
                      "one": { "stringUnit": { "state": "translated", "value": "%@ has one item" } },
                      "other": { "stringUnit": { "state": "translated", "value": "%@ has %lld items" } }
                    }
                  }
                }
              }
            }
          }
        }
        """)
        #expect(outputs.keys.sorted() == ["en.lproj/Localizable.stringsdict"])
        let entry = try #require(try dictionary(outputs["en.lproj/Localizable.stringsdict"])["%@ has %lld items"] as? [String: Any])
        #expect(entry["NSStringLocalizedFormatKey"] as? String == "%2$#@__plural@")
        let rule = try #require(entry["__plural"] as? [String: String])
        #expect(rule == [
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "lld",
            "one": "%@ has one item",
            "other": "%@ has %lld items",
        ])
    }

    @Test func compilesSubstitutions() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "%lld files in %lld folders": {
              "localizations": {
                "ko": {
                  "stringUnit": { "state": "translated", "value": "폴더 %#@folders@에 파일 %#@files@" },
                  "substitutions": {
                    "files": {
                      "argNum": 1,
                      "formatSpecifier": "lld",
                      "variations": { "plural": { "other": { "stringUnit": { "state": "translated", "value": "%arg개" } } } }
                    },
                    "folders": {
                      "argNum": 2,
                      "formatSpecifier": "lld",
                      "variations": { "plural": { "other": { "stringUnit": { "state": "translated", "value": "%arg개" } } } }
                    }
                  }
                }
              }
            }
          }
        }
        """)
        let stringsdict = try dictionary(outputs["ko.lproj/Localizable.stringsdict"])
        let entry = try #require(stringsdict["%lld files in %lld folders"] as? [String: Any])
        #expect(entry["NSStringLocalizedFormatKey"] as? String == "폴더 %2$#@folders@에 파일 %1$#@files@")
        #expect((entry["files"] as? [String: String])?["other"] == "%1$lld개")
        #expect((entry["folders"] as? [String: String])?["other"] == "%2$lld개")
        // The source language falls back to the key.
        #expect(try strings(outputs["en.lproj/Localizable.strings"]) == ["%lld files in %lld folders": "%lld files in %lld folders"])
    }

    @Test func compilesDeviceVariations() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "Tap": {
              "localizations": {
                "en": {
                  "variations": {
                    "device": {
                      "iphone": { "stringUnit": { "state": "translated", "value": "Tap" } },
                      "mac": { "stringUnit": { "state": "translated", "value": "Click" } },
                      "other": { "stringUnit": { "state": "translated", "value": "Select" } }
                    }
                  }
                }
              }
            }
          }
        }
        """)
        let entry = try #require(try dictionary(outputs["en.lproj/Localizable.stringsdict"])["Tap"] as? [String: Any])
        #expect(entry["NSStringDeviceSpecificRuleType"] as? [String: String] == ["iphone": "Tap", "mac": "Click"])
        // Other devices (e.g. iPad) use the .strings value.
        #expect(try strings(outputs["en.lproj/Localizable.strings"]) == ["Tap": "Select"])
    }

    @Test func parsesFormatSpecifiers() {
        #expect(FormatSpecifier.parse("%@ has %lld items, 100%%") == [
            FormatSpecifier(position: 1, valueType: "@"),
            FormatSpecifier(position: 2, valueType: "lld"),
        ])
        #expect(FormatSpecifier.parse("%2$@ then %1$.2f") == [
            FormatSpecifier(position: 2, valueType: "@"),
            FormatSpecifier(position: 1, valueType: "f"),
        ])
        #expect(FormatSpecifier.parse("%#@files@ and %d") == [FormatSpecifier(position: 1, valueType: "d")])
    }

    @Test func makesFormatsPositional() {
        #expect(FormatSpecifier.positional("%@ has %#@apples@", variables: ["apples": 2]) == "%1$@ has %2$#@apples@")
        // The other specifiers take the arguments the variables don't, even out of order.
        #expect(FormatSpecifier.positional("%#@apples@ for %@", variables: ["apples": 2]) == "%2$#@apples@ for %1$@")
        #expect(FormatSpecifier.positional("%2$@: %#@n@, 100%% %.1f", variables: ["n": 3]) == "%2$@: %3$#@n@, 100%% %1$.1f")
    }

    @Test func dryRunListsTheFilesItWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "XCStringsToolTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {
          "sourceLanguage": "en",
          "strings": {
            "Hello": { "localizations": { "ko": { "stringUnit": { "state": "translated", "value": "안녕" } } } }
          }
        }
        """.utf8).write(to: directory.appending(path: "Strings.xcstrings"))

        let tool = XCStringsTool()
        let dryRun = try await tool.execute(
            commandLine: ["xcstringstool", "compile", "--dry-run", "--output-directory", "out", "Strings.xcstrings"],
            workingDirectory: directory.path,
            environment: [:]
        )
        guard case .result(.exit(0), let stdout, _) = dryRun else {
            Issue.record("dry run failed: \(dryRun)")
            return
        }
        let listed = String(decoding: stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        let base = directory.standardizedFileURL.path
        #expect(listed == ["\(base)/out/en.lproj/Strings.strings", "\(base)/out/ko.lproj/Strings.strings"])
        #expect(!FileManager.default.fileExists(atPath: listed[0]))

        let compile = try await tool.execute(
            commandLine: ["xcstringstool", "compile", "--output-directory", "out", "Strings.xcstrings"],
            workingDirectory: directory.path,
            environment: [:]
        )
        guard case .result(.exit(0), _, _) = compile else {
            Issue.record("compile failed: \(compile)")
            return
        }
        for path in listed { #expect(FileManager.default.fileExists(atPath: path)) }
    }

    @Test func reportsInvalidCatalogs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "XCStringsToolTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "Bad.xcstrings"))

        let result = try await XCStringsTool().execute(
            commandLine: ["xcstringstool", "compile", "--dry-run", "--output-directory", "out", "Bad.xcstrings"],
            workingDirectory: directory.path,
            environment: [:]
        )
        guard case .result(.exit(1), _, let stderr) = result else {
            Issue.record("expected failure: \(result)")
            return
        }
        #expect(String(decoding: stderr, as: UTF8.self).hasPrefix("Bad.xcstrings: error: "))
    }

    @Test func skipsUntranslatedStrings() throws {
        let catalog = """
        {
          "sourceLanguage": "en",
          "strings": {
            "Hello": {
              "localizations": {
                "en": { "stringUnit": { "state": "new", "value": "Hi" } },
                "ko": { "stringUnit": { "state": "new", "value": "" } }
              }
            },
            "%lld apples": {
              "localizations": {
                "ko": {
                  "variations": {
                    "plural": {
                      "other": { "stringUnit": { "state": "new", "value": "" } }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let outputs = try compile(catalog)
        #expect(outputs.keys.sorted() == ["en.lproj/Localizable.strings"])
        // Source language values are compiled even when new, e.g. those from `defaultValue:`.
        #expect(try strings(outputs["en.lproj/Localizable.strings"]) == ["Hello": "Hi", "%lld apples": "%lld apples"])

        let forced = try compile(catalog, forceBuildAllStrings: true)
        #expect(try strings(forced["en.lproj/Localizable.strings"]) == ["Hello": "Hi", "%lld apples": "%lld apples"])
        #expect(try strings(forced["ko.lproj/Localizable.strings"]) == ["Hello": ""])
        #expect(forced["ko.lproj/Localizable.stringsdict"] != nil)
    }

    @Test func findsThePluralCountWhenFormsOmitIt() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "%@ has %lld items": {
              "localizations": {
                "en": {
                  "variations": {
                    "plural": {
                      "one": { "stringUnit": { "state": "translated", "value": "%@ has one item" } },
                      "other": { "stringUnit": { "state": "translated", "value": "%@ has many items" } }
                    }
                  }
                }
              }
            }
          }
        }
        """)
        let stringsdict = try dictionary(outputs["en.lproj/Localizable.stringsdict"])
        let entry = try #require(stringsdict["%@ has %lld items"] as? [String: Any])
        #expect(entry["NSStringLocalizedFormatKey"] as? String == "%2$#@__plural@")
        #expect((entry["__plural"] as? [String: String])?["NSStringFormatValueTypeKey"] == "lld")

        // Another number in the forms isn't mistaken for the count.
        let boxes = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "%@ has %lld items in %lld boxes": {
              "localizations": {
                "en": {
                  "variations": {
                    "plural": {
                      "other": { "stringUnit": { "state": "translated", "value": "%1$@ has many items in %3$lld boxes" } }
                    }
                  }
                }
              }
            }
          }
        }
        """)
        let boxesEntry = try #require(
            try dictionary(boxes["en.lproj/Localizable.stringsdict"])["%@ has %lld items in %lld boxes"] as? [String: Any]
        )
        #expect(boxesEntry["NSStringLocalizedFormatKey"] as? String == "%2$#@__plural@")
    }

    @Test func requiresAnOtherPluralCase() throws {
        let outputs = try compile("""
        {
          "sourceLanguage": "en",
          "strings": {
            "%lld items": {
              "localizations": {
                "ko": {
                  "variations": {
                    "plural": {
                      "one": { "stringUnit": { "state": "translated", "value": "%lld개" } },
                      "other": { "stringUnit": { "state": "new", "value": "" } }
                    }
                  }
                }
              }
            },
            "%lld files in %lld folders": {
              "localizations": {
                "ko": {
                  "stringUnit": { "state": "translated", "value": "%#@files@" },
                  "substitutions": {
                    "files": {
                      "argNum": 1,
                      "formatSpecifier": "lld",
                      "variations": {
                        "plural": { "one": { "stringUnit": { "state": "translated", "value": "%arg개" } } }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """)
        #expect(outputs["ko.lproj/Localizable.stringsdict"] == nil)
    }

    @Test func rejectsLanguagesThatAreNotIdentifiers() {
        #expect(throws: StringCatalogCompiler.CompileError.self) {
            try compile(#"{"sourceLanguage": "../en", "strings": {"Hello": {}}}"#)
        }
    }

    @Test func leavesOutNestedPluralCases() throws {
        var compiler = StringCatalogCompiler()
        let outputs = try compiler.compile(catalog: Data("""
        {
          "sourceLanguage": "en",
          "strings": {
            "%lld items": {
              "localizations": {
                "en": {
                  "variations": {
                    "plural": {
                      "one": {
                        "variations": {
                          "device": { "other": { "stringUnit": { "state": "translated", "value": "%lld item" } } }
                        }
                      },
                      "other": { "stringUnit": { "state": "translated", "value": "%lld items" } }
                    }
                  }
                }
              }
            }
          }
        }
        """.utf8), tableName: "Localizable")
        let stringsdict = try dictionary(outputs.first { $0.path == "en.lproj/Localizable.stringsdict" }?.contents)
        let entry = try #require(stringsdict["%lld items"] as? [String: Any])
        #expect((entry["__plural"] as? [String: String])?.keys.contains("one") == false)
        #expect(compiler.warnings.count == 1)
    }

    @Test(arguments: [false, true])
    func writesPlaceholderSymbols(hasManualStrings: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "XCStringsToolTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extractionState = hasManualStrings ? "manual" : "extracted_with_value"
        try Data(#"{"sourceLanguage": "en", "strings": {"key": {"extractionState": "\#(extractionState)"}}}"#.utf8)
            .write(to: directory.appending(path: "Strings.xcstrings"))

        let result = try await XCStringsTool().execute(
            commandLine: [
                "xcstringstool", "generate-symbols", "--language", "swift",
                "--output-directory", "DerivedSources", "Strings.xcstrings",
            ],
            workingDirectory: directory.path,
            environment: [:]
        )
        guard case .result(.exit(0), _, let stderr) = result else {
            Issue.record("generate-symbols failed: \(result)")
            return
        }
        #expect(String(decoding: stderr, as: UTF8.self).contains("warning:") == hasManualStrings)
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "DerivedSources/GeneratedStringSymbols_Strings.swift").path
        ))
    }

    // MARK: - Helpers

    private func compile(
        _ json: String,
        languages: Set<String>? = nil,
        forceBuildAllStrings: Bool = false
    ) throws -> [String: Data] {
        var compiler = StringCatalogCompiler(languages: languages, forceBuildAllStrings: forceBuildAllStrings)
        let outputs = try compiler.compile(catalog: Data(json.utf8), tableName: "Localizable")
        return Dictionary(uniqueKeysWithValues: outputs.map { ($0.path, $0.contents) })
    }

    private func dictionary(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func strings(_ data: Data?) throws -> [String: String] {
        try #require(try dictionary(data) as? [String: String])
    }
}
