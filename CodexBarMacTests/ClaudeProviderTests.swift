import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class ClaudeProviderTests: XCTestCase {
    deinit {}

    func testClaudeUsageParserReadsOAuthUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "de_DE")
        )
        let payload = """
        {
          "five_hour": {
            "utilization": 42,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 81,
            "resets_at": "2030-01-08T00:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro",
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.title, "Claude (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
    }

    func testClaudeUsageParserSurfacesOAuthAppsWeeklyLimitSeparately() throws {
        let payload = """
        {
          "five_hour": {
            "utilization": 12,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 34,
            "resets_at": "2030-01-08T00:00:00Z"
          },
          "seven_day_oauth_apps": {
            "utilization": 61,
            "resets_at": "2030-01-08T12:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "Weekly usage limit",
            "OAuth apps weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [12, 34, 61])
    }

    func testClaudeUsageParserLabelsOAuthAppsWeeklyLimitWhenAllModelWeeklyIsAbsent() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"seven_day_oauth_apps":{"utilization":55,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["OAuth apps weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [55])
    }

    func testClaudeUsageParserPreservesSubOnePercentOAuthUtilization() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":0.5,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 0.5)
    }

    func testClaudeUsageParserDecodesOptionalSectionsIndependently() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":"2030-01-01T02:00:00Z"},"seven_day":[],"spend":[],"extra_usage":[]}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [13])
        XCTAssertTrue(result.monetaryMetrics.isEmpty)
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testClaudeUsageParserDecodesStructuredLimitsElementByElement() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"session","percent":7,"is_active":"yes"},{"kind":"session","percent":13},"unexpected",{"kind":"weekly_all","group":[],"percent":24},{"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T02:00:00Z"}]}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "Weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [13, 36])
    }

    func testClaudeUsageParserLossilyDecodesLimitResetAndScopeFields() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":[]},"limits":[{"kind":"session","percent":7,"scope":"unexpected"},{"kind":"session","percent":8,"scope":{"model":[]}},{"kind":"session","percent":9,"scope":{"model":{"display_name":[]}}},{"kind":"weekly_all","percent":36,"resets_at":[]}]}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "Weekly usage limit",
            "5 hour usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [36, 13])
        XCTAssertEqual(result.bars.map(\.resetsAt), [nil, nil])
    }

    func testClaudeUsageParserRejectsFullyUnusableLossyResponse() {
        let result = ClaudeUsageParser.parse(
            Data(#"{"five_hour":[],"seven_day":{"utilization":"unknown"},"limits":["unexpected",{"kind":"weekly_all","percent":"unknown"}],"spend":[],"extra_usage":[]}"#.utf8),
            subscriptionType: "pro"
        )

        XCTAssertNil(result)
    }

    func testClaudeUsageParserReadsStructuredAndScopedLimitsWithoutDuplicates() throws {
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T00:00:00Z"},
          "seven_day": {"utilization": 0.88, "resets_at": "2030-01-08T00:00:00Z"},
          "limits": [
            {"kind":"session","percent":15,"is_active":true},
            {"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T00:00:00Z","is_active":true},
            {"kind":"weekly_scoped","percent":71,"resets_at":"2030-01-08T00:00:00.838164+00:00","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max_20x"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "All models weekly usage limit",
            "Fable weekly usage limit",
            "Claude Sonnet 4.5 weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [15, 36, 71, 49])
        XCTAssertEqual(result.bars.last?.stableKey, "weekly-scoped-claudesonnet45")
    }

    func testClaudeUsageParserShowsObservedInactiveFableWeeklyLimit() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","percent":11,"resets_at":"2030-01-01T02:00:00Z","is_active":true},
            {"kind":"weekly_all","percent":9,"resets_at":"2030-01-08T04:00:00Z","is_active":false},
            {"kind":"weekly_scoped","percent":5,"resets_at":"2030-01-08T04:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":false}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "All models weekly usage limit",
            "Fable weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [11, 9, 5])
    }

    func testClaudeUsageParserReadsScopedWeeklyRateLimitHeaders() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.42",
                "anthropic-ratelimit-unified-5h-reset": "1893456000",
                "anthropic-ratelimit-unified-7d-utilization": "0.65",
                "anthropic-ratelimit-unified-7d-reset": "1894060800",
                "anthropic-ratelimit-unified-7d_sonnet-utilization": "0.88",
                "anthropic-ratelimit-unified-7d_sonnet-reset": "1894060800",
                "anthropic-ratelimit-unified-7d-opus-utilization": "0.31",
                "anthropic-ratelimit-unified-7d-opus-reset": "1894060800",
            ],
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "Weekly usage limit",
            "Sonnet weekly usage limit",
            "Opus weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [42, 65, 88, 31])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "session",
            "weekly-all",
            "weekly-scoped-sonnet",
            "weekly-scoped-opus",
        ])
    }

    func testClaudeUsageParserMatchesRateLimitHeadersCaseInsensitively() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "Anthropic-Ratelimit-Unified-5H-Utilization": "0.42",
                "ANTHROPIC-RATELIMIT-UNIFIED-5H-RESET": "1893456000",
            ],
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit"])
        XCTAssertEqual(result.bars.first?.used, 42)
    }

    func testClaudeUsageParserReadsCurrencyAwareUsageCredits() throws {
        let payload = """
        {
          "limits": [{"kind":"weekly_all","percent":24,"is_active":true}],
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 5000,
            "used_credits": 1250,
            "currency": "EUR",
            "decimal_places": 2
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 24)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(result.monetaryMetrics.map(\.amount), [Decimal(string: "12.5")!, Decimal(50), Decimal(string: "37.5")!])
        XCTAssertEqual(result.monetaryMetrics.map(\.currencyCode), ["EUR", "EUR", "EUR"])
        XCTAssertEqual(result.monetaryMetrics.last?.detail, "Not a prepaid balance")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertFalse(result.hasReachedSpendLimit)
    }

    func testClaudeUsageParserRepresentsDisabledUnlimitedAndMalformedExtraUsage() throws {
        let disabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(disabled.usageMessages, ["Usage credits are disabled: Not funded."])
        XCTAssertTrue(disabled.monetaryMetrics.isEmpty)

        let unlimited = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":250,"currency":"GBP","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unlimited.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(unlimited.usageMessages, ["Usage credits are enabled with no monthly spend limit reported."])

        let malformed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"unknown","percent":50}],"extra_usage":{"is_enabled":true,"used_credits":10,"currency":"US"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(malformed.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            malformed.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let missingCurrency = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let reachedLimit = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":5000,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(reachedLimit.hasReachedSpendLimit)
        XCTAssertEqual(
            reachedLimit.usageMessages,
            ["The monthly usage-credit spend limit has been reached."]
        )

        let lossyExtraUsage = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":24,"is_active":true}],"extra_usage":{"is_enabled":true,"used_credits":"not-a-number","monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(lossyExtraUsage.bars.first?.used, 24)
        XCTAssertTrue(lossyExtraUsage.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            lossyExtraUsage.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let lossyOptionalFields = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":18,"is_active":true}],"extra_usage":{"is_enabled":"yes","used_credits":1250,"monthly_limit":5000,"currency":123,"disabled_reason":false,"decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(lossyOptionalFields.bars.first?.used, 18)
        XCTAssertEqual(lossyOptionalFields.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(lossyOptionalFields.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertEqual(
            lossyOptionalFields.usageMessages,
            ["Usage-credit enabled status was not reported."]
        )
    }

    func testClaudeUsageParserPrefersSpendPayloadOverExtraUsage() throws {
        let withLimit = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":40,"is_active":true}],"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"balance":null},"extra_usage":{"is_enabled":true,"used_credits":99,"monthly_limit":100,"currency":"EUR","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(withLimit.bars.first?.used, 40)
        XCTAssertEqual(withLimit.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(withLimit.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(withLimit.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertFalse(withLimit.hasReachedSpendLimit)

        let balanceOnly = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"balance":{"amount_minor":500,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(balanceOnly.monetaryMetrics.map(\.kind), [.balance])
        XCTAssertEqual(balanceOnly.monetaryMetrics.first?.amount, Decimal(5))
        XCTAssertEqual(balanceOnly.monetaryMetrics.first?.detail, "Prepaid balance")

        let negativeBalance = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"balance":{"amount_minor":-250,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(negativeBalance.monetaryMetrics.map(\.kind), [.balance])
        XCTAssertEqual(negativeBalance.monetaryMetrics.first?.minorUnits, Decimal(-250))
        XCTAssertEqual(negativeBalance.monetaryMetrics.first?.amount, Decimal(string: "-2.5")!)

        let limitAndBalance = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"balance":{"amount_minor":800,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            limitAndBalance.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom, .balance]
        )
        XCTAssertEqual(limitAndBalance.monetaryMetrics.map(\.minorUnits), [
            Decimal(1250), Decimal(5000), Decimal(3750), Decimal(800),
        ])

        let disabledSpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":false,"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"balance":null}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(disabledSpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(disabledSpend.usageMessages, ["Usage credits are disabled."])

        let lossySpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"session","percent":12,"is_active":true}],"spend":{"enabled":true,"used":"broken"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(lossySpend.bars.first?.used, 12)
        XCTAssertTrue(lossySpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            lossySpend.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let unusableSpendFallsBackToExtraUsage = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":"broken"},"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            unusableSpendFallsBackToExtraUsage.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom]
        )
        XCTAssertEqual(
            unusableSpendFallsBackToExtraUsage.monetaryMetrics.map(\.minorUnits),
            [Decimal(1250), Decimal(5000), Decimal(3750)]
        )
    }

    func testClaudeUsageParserFillsMissingSpendMetricsFromExtraUsage() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"balance":{"amount_minor":800,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))

        XCTAssertEqual(
            result.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom, .balance]
        )
        XCTAssertEqual(
            result.monetaryMetrics.map(\.minorUnits),
            [Decimal(1250), Decimal(5000), Decimal(3750), Decimal(800)]
        )
        XCTAssertTrue(result.usageMessages.isEmpty)

        let missingSpent = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"balance":{"amount_minor":800,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":9999,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            missingSpent.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom, .balance]
        )
        XCTAssertEqual(
            missingSpent.monetaryMetrics.map(\.minorUnits),
            [Decimal(1250), Decimal(5000), Decimal(3750), Decimal(800)]
        )

        let missingSpentWithLimitOnlyFallback = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":"broken"},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            missingSpentWithLimitOnlyFallback.monetaryMetrics.map(\.kind),
            [.spendLimit]
        )
        XCTAssertEqual(
            missingSpentWithLimitOnlyFallback.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )
    }

    func testClaudeUsageParserPreservesFallbackNoLimitMessage() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"used":"broken"},"extra_usage":{"is_enabled":true,"used_credits":1250,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))

        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [Decimal(1250)])
        XCTAssertEqual(
            result.usageMessages,
            ["Usage credits are enabled with no monthly spend limit reported."]
        )

        let unknownEnabledState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"used":"broken"},"extra_usage":{"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            unknownEnabledState.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom]
        )
        XCTAssertEqual(
            unknownEnabledState.usageMessages,
            ["Usage-credit enabled status was not reported."]
        )
    }

    func testClaudeUsageParserDoesNotDeriveHeadroomFromIncompatibleFallbackMetrics() throws {
        let differentCurrency = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"used_credits":99,"monthly_limit":5000,"currency":"EUR","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(differentCurrency.monetaryMetrics.map(\.kind), [.spent, .spendLimit])
        XCTAssertEqual(differentCurrency.monetaryMetrics.map(\.currencyCode), ["USD", "EUR"])

        let differentPrecision = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":3}},"extra_usage":{"is_enabled":true,"used_credits":99,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(differentPrecision.monetaryMetrics.map(\.kind), [.spent, .spendLimit])
        XCTAssertEqual(differentPrecision.monetaryMetrics.map(\.decimalPlaces), [3, 2])

        let unsupportedPrecision = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":7}},"extra_usage":{"is_enabled":true,"used_credits":99,"monthly_limit":5000,"currency":"USD","decimal_places":8}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(unsupportedPrecision.monetaryMetrics.isEmpty)
        XCTAssertEqual(unsupportedPrecision.usageMessages, [
            "Usage credits are enabled, but monetary details are temporarily unavailable.",
        ])
    }

    func testClaudeUsageParserUsesExplicitEnabledStateAcrossSpendPayloads() throws {
        let fallbackDisabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"used":{"amount_minor":1250,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(fallbackDisabled.monetaryMetrics.isEmpty)
        XCTAssertEqual(fallbackDisabled.usageMessages, ["Usage credits are disabled: Not funded."])

        let providerEnabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(providerEnabled.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(
            providerEnabled.usageMessages,
            ["Usage credits are enabled with no monthly spend limit reported."]
        )

        let providerDisabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":false},"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(providerDisabled.monetaryMetrics.isEmpty)
        XCTAssertEqual(providerDisabled.usageMessages, ["Usage credits are disabled."])
    }

    func testClaudeCredentialStorePreservesFilePermissionsAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        let original = """
        {
          "otherEntry": {"enabled": true},
          "claudeAiOauth": {
            "accessToken": "old-access",
            "refreshToken": "refresh-token",
            "expiresAt": 1000,
            "scopes": ["user:inference", "user:profile"]
          }
        }
        """
        try Data(original.utf8).write(to: URL(fileURLWithPath: credentialsPath))
        _ = chmod(credentialsPath, 0o600)

        try ClaudeCredentialStore.saveCredentials(
            ClaudeCredentials(
                expiresAt: 4_000_000_000_000,
                accessToken: "new-access",
                refreshToken: "refresh-token"
            ),
            to: .file(credentialsPath)
        )

        var attributes = stat()
        XCTAssertEqual(stat(credentialsPath, &attributes), 0)
        XCTAssertEqual(attributes.st_mode & 0o777, 0o600)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: credentialsPath))
        ) as? [String: Any]
        let otherEntry = root?["otherEntry"] as? [String: Any]
        XCTAssertEqual(otherEntry?["enabled"] as? Bool, true)
        let oauth = root?["claudeAiOauth"] as? [String: Any]
        XCTAssertEqual(oauth?["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth?["refreshToken"] as? String, "refresh-token")
        XCTAssertEqual(oauth?["scopes"] as? [String], ["user:inference", "user:profile"])
    }

    func testClaudeCredentialStoreSurfacesPermissionRestorationFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        var requestedPath: String?
        var requestedMode: mode_t?

        XCTAssertThrowsError(
            try ClaudeCredentialStore.saveCredentials(
                ClaudeCredentials(
                    expiresAt: 4_000_000_000_000,
                    accessToken: "redacted-access",
                    refreshToken: "redacted-refresh"
                ),
                to: .file(credentialsPath),
                settingPermissionsWith: { path, mode in
                    requestedPath = path
                    requestedMode = mode
                    return -1
                }
            )
        ) { error in
            guard case ClaudeCredentialStoreError.unableToSecureFile = error else {
                return XCTFail("Expected unableToSecureFile, got \(error)")
            }
        }

        XCTAssertEqual(requestedPath, credentialsPath)
        XCTAssertEqual(requestedMode, 0o600)
    }

    func testClaudeAuthURLUsesPKCELoopbackFlow() throws {
        let url = ClaudeWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1461/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1461/callback")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
    }

    func testClaudeTokenRequestBodyUsesAuthorizationCodeExchange() throws {
        let data = ClaudeWebAuthService.makeTokenRequestBody(
            code: "code value",
            redirectURI: "http://localhost:1461/callback",
            state: "state value",
            codeVerifier: "verifier value"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "code value")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:1461/callback")
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(body["code_verifier"], "verifier value")
        XCTAssertEqual(body["state"], "state value")
    }

    @MainActor
    func testClaudeBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = ClaudeWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        var presentedURL: URL?

        do {
            _ = try await service.signIn {
                presentedURL = $0
                return true
            }
            XCTFail("Expected Claude browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .callbackTimedOut)
        }

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(components.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    @MainActor
    func testClaudeBrowserSignInExchangesCallbackForCredentials() async throws {
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "access_token": "redacted-access-token",
            "refresh_token": "redacted-refresh-token",
            "expires_at": 4_000_003_600_000,
            "subscription_type": "synthetic_subscription",
            "rate_limit_tier": "synthetic_tier",
        ])

        let result = try await performClaudeTokenExchange(responseBody: responseBody) { request, authorizationURL in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let authorization = try XCTUnwrap(
                URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
            )
            let redirectURI = try XCTUnwrap(authorization.queryItemValue(named: "redirect_uri"))
            let state = try XCTUnwrap(authorization.queryItemValue(named: "state"))
            XCTAssertEqual(state, deterministicOAuthValue(byteCount: 32))
            XCTAssertEqual(URL(string: redirectURI)?.path, "/callback")

            let requestData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: String])
            XCTAssertEqual(body["grant_type"], "authorization_code")
            XCTAssertEqual(body["code"], syntheticOAuthCode)
            XCTAssertEqual(body["redirect_uri"], redirectURI)
            XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
            XCTAssertEqual(body["code_verifier"], deterministicOAuthValue(byteCount: 64))
            XCTAssertEqual(body["state"], state)
        }

        XCTAssertEqual(result.credentials.accessToken, "redacted-access-token")
        XCTAssertEqual(result.credentials.refreshToken, "redacted-refresh-token")
        XCTAssertEqual(result.credentials.expiresAt, 4_000_003_600_000)
        XCTAssertEqual(result.credentials.subscriptionType, "synthetic_subscription")
        XCTAssertEqual(result.credentials.rateLimitTier, "synthetic_tier")
    }

    @MainActor
    func testClaudeBrowserSignInSanitizesNonSuccessTokenResponse() async throws {
        let responseBody = Data(
            #"{"error":"invalid_grant","error_description":"redacted-authorization-code redacted-access-token untrusted detail"}"#.utf8
        )

        do {
            _ = try await performClaudeTokenExchange(statusCode: 400, responseBody: responseBody)
            XCTFail("Expected a rejected Claude token exchange.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeWebAuthService.AuthError,
                .tokenExchangeFailed("HTTP 400 (invalid_grant)")
            )
            XCTAssertFalse(error.localizedDescription.contains(syntheticOAuthCode))
            XCTAssertFalse(error.localizedDescription.contains("redacted-access-token"))
            XCTAssertFalse(error.localizedDescription.contains("untrusted detail"))
        }
    }

    @MainActor
    func testClaudeBrowserSignInRejectsMalformedSuccessResponse() async throws {
        do {
            _ = try await performClaudeTokenExchange(responseBody: Data(#"{"access_token":42}"#.utf8))
            XCTFail("Expected a malformed Claude token response to fail.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .invalidTokenResponse)
        }
    }

    @MainActor
    func testClaudeBrowserSignInRejectsSuccessResponseWithoutAccessToken() async throws {
        do {
            _ = try await performClaudeTokenExchange(
                responseBody: Data(#"{"refresh_token":"redacted-refresh-token"}"#.utf8)
            )
            XCTFail("Expected a Claude token response without an access token to fail.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .invalidTokenResponse)
            XCTAssertFalse(error.localizedDescription.contains("redacted-refresh-token"))
        }
    }

    @MainActor
    func testClaudeBrowserSignInSurfacesOnlySafeOAuthErrorCode() async throws {
        let responseBody = Data(
            #"{"error":"access_denied","error_description":"redacted-authorization-code untrusted denial"}"#.utf8
        )

        do {
            _ = try await performClaudeTokenExchange(responseBody: responseBody)
            XCTFail("Expected an OAuth error payload to fail Claude sign-in.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeWebAuthService.AuthError,
                .tokenExchangeFailed("access_denied")
            )
            XCTAssertFalse(error.localizedDescription.contains(syntheticOAuthCode))
            XCTAssertFalse(error.localizedDescription.contains("untrusted denial"))
        }
    }

    func testTokenEndpointErrorFormatterRedactsUntrustedDetails() {
        let body = Data(#"{"error":"invalid_grant","error_description":"authorization code=secret-code client_id=secret-client"}"#.utf8)

        let message = TokenEndpointErrorFormatter.message(statusCode: 400, body: body)

        XCTAssertEqual(message, "HTTP 400 (invalid_grant)")
        XCTAssertFalse(message.contains("secret-code"))
        XCTAssertFalse(message.contains("secret-client"))
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(
                statusCode: 502,
                body: Data("authorization: Bearer secret-token".utf8)
            ),
            "HTTP 502"
        )
    }

    func testClaudeCredentialStoreRejectsWhitespaceOnlyAccessTokens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data("""
        {
          "claudeAiOauth": {
            "accessToken": "   ",
            "refreshToken": "refresh-token",
            "expiresAt": 4000000000000
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: credentialsPath))

        XCTAssertNil(ClaudeCredentialStore.readCredentials(
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            credentialsFilePath: credentialsPath
        ))
        XCTAssertNil(ClaudeCredentialStore.readCredentials(from: .file(credentialsPath)))
    }

    func testClaudeUsageProviderReadsLocalCredentialsFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer claude-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(result.bars.map(\.used), [25, 50])
    }

    func testClaudeUsageProviderUsesBrowserCredentialWhenLocalCredentialsAreAbsent() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .claude,
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 4_000_000_000_000,
                accessToken: "browser-claude-access",
                refreshToken: "redacted-refresh"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(".credentials.json").path,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-claude-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":31,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 31)
    }

    func testClaudeBrowserConfigurationPrefersHealthyLocalCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 2_000_003_600,
            accessToken: "healthy-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .claude, authMethod: .browserSession)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 2_000_003_600,
                accessToken: "browser-access"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer healthy-local")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":21,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 21)
    }

    func testClaudeAdditionalBrowserAccountPrefersItsSavedCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 2_000_003_600,
            accessToken: "shared-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let defaultConfiguration = ProviderAccountConfiguration(
            providerID: .claude,
            authMethod: .browserSession
        )
        let additionalConfiguration = ProviderAccountConfiguration(
            id: "claude.additional",
            providerID: .claude,
            authMethod: .browserSession
        )
        for (configuration, accessToken) in [
            (defaultConfiguration, "default-browser"),
            (additionalConfiguration, "additional-browser"),
        ] {
            try secretStore.saveSecret(
                ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                    expiresAt: 2_000_003_600,
                    accessToken: accessToken
                )),
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        var requestedTokens: [String] = []
        MockURLProtocol.handler = { request in
            requestedTokens.append(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")))
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":21,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        _ = try await provider.fetchUsage(for: defaultConfiguration)
        _ = try await provider.fetchUsage(for: additionalConfiguration)

        XCTAssertEqual(requestedTokens, ["Bearer shared-local", "Bearer additional-browser"])
    }

    func testClaudeBrowserConfigurationFallsBackWhenLocalCredentialIsExpired() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 1_999_999_900,
            accessToken: "expired-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .claude, authMethod: .browserSession)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 2_000_003_600,
                accessToken: "browser-access"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":32,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 32)
    }

    func testClaudeBrowserConfigurationFallsBackWhenLocalCredentialIsRejected() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 2_000_003_600,
            accessToken: "revoked-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .claude, authMethod: .browserSession)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 2_000_003_600,
                accessToken: "browser-access"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer revoked-local" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":43,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 43)
    }

    func testClaudeUsageProviderReturnsMonetaryOnlyWithoutMessagesProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(try XCTUnwrap(result.monetaryMetrics.first?.amount), Decimal(string: "12.5")!)
        XCTAssertTrue(result.isIncompleteRefresh)
    }

    func testClaudeUsageProviderDoesNotProbeMessagesWhenOAuthPayloadIsUnrecognized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.subtitle, "Claude usage did not include rate-limit windows.")
        XCTAssertTrue(result.isIncompleteRefresh)
    }

    func testClaudeUsageProviderPreservesCachedBarsWhenOAuthReturnsMonetaryOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )

        var oauthCalls = 0
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            oauthCalls += 1
            if oauthCalls == 1 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":33,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let seeded = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))
        XCTAssertEqual(seeded.bars.map(\.used), [33])

        let refreshed = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))
        XCTAssertEqual(oauthCalls, 2)
        XCTAssertEqual(refreshed.bars.map(\.used), [33])
        XCTAssertEqual(refreshed.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(try XCTUnwrap(refreshed.monetaryMetrics.first?.amount), Decimal(string: "12.5")!)
        XCTAssertTrue(refreshed.isIncompleteRefresh)
    }

    func testClaudeUsageProviderDoesNotProbeMessagesWhenOAuthUsageIsForbidden() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.subtitle, "Claude credential lacks permission to read subscription usage.")
        XCTAssertTrue(result.isIncompleteRefresh)
    }

    func testClaudeUsageProviderPreservesCachedBarsWhenOAuthUsageIsForbidden() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            if requestCount == 1 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":37,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let fresh = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))
        let forbidden = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(forbidden.bars, fresh.bars)
        XCTAssertTrue(forbidden.subtitle.contains("lacks permission"))
        XCTAssertTrue(forbidden.subtitle.contains("Showing last known data."))
        XCTAssertTrue(forbidden.isIncompleteRefresh)
    }

    func testClaudeUsageProviderPreservesSnapshotAfter401TriggeredRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "old-access",
            refreshToken: "refresh-token"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var usageRequestCount = 0

        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/oauth/token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"refresh-token","expires_in":3600}"#.utf8)
                )
            }

            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            usageRequestCount += 1
            if usageRequestCount == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            if usageRequestCount == 2 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8)
                )
            }

            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "60"]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let firstResult = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(firstResult.bars.map(\.used), [25, 50])

        let secondResult = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(secondResult.bars.map(\.used), [25, 50])
        XCTAssertTrue(secondResult.subtitle.contains("Showing last known data."))
    }

}

