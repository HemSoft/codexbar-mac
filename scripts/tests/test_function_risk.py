"""Regression fixtures exercise coverage joining and the required gate without Xcode."""
import copy
from fractions import Fraction
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('function_risk', Path(__file__).parents[1] / 'function-risk/measure.py')
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)


class FunctionRiskTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.patcher = patch.object(METRICS, 'ROOT', self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        (self.root / 'Example.swift').write_text('func uncovered(_ value: Int) {\n' + '\n'.join(f'    if value == {i} {{ print(value) }}' for i in range(6)) + '\n}\n')
        self.declaration = dict(path='Example.swift', symbol='.func uncovered ( _ value : Int )', kind='function', line=1, bodyLine=1, endLine=8, lintLine=1, lintColumn=1)
        self.complexity = [dict(file=str(self.root / 'Example.swift'), line=1, character=1, rule_id='cyclomatic_complexity', reason='Function should have complexity -1 or less; currently complexity is 6')]
        self.function = dict(name='uncovered(_:)', lineNumber=1, coveredLines=0, executableLines=8)
        self.target = dict(name='Example.app', coveredLines=0, executableLines=8, files=[dict(path=str(self.root / 'Example.swift'), coveredLines=0, executableLines=8, functions=[self.function])])
        self.policy = dict(tools=dict(swiftlint='fixture-version'), platforms=dict(mac=dict(coverage_targets=['Example.app'])), excluded_files={}, excluded_symbols={})
        self.baseline = dict(platforms=dict(mac=dict(high_risk={}, unmatched={})))

    def measure(self, declarations=None, targets=None):
        return METRICS.measure('mac', declarations or [self.declaration], self.complexity, dict(targets=targets or [self.target]), {'Example.swift'}, self.policy)

    def test_uncovered_branch_fixture_fails_then_restored_coverage_passes(self):
        report = self.measure()
        self.assertEqual(report['functions'][0]['crap_exact'], '42/1')
        self.assertIn('New production risk above 30', METRICS.gate(report, self.baseline)[0])
        self.function['coveredLines'] = 8
        self.assertEqual(METRICS.gate(self.measure(), self.baseline), [])

    def test_worsened_baseline_fails_even_below_display_precision(self):
        report = self.measure()
        row = report['functions'][0]
        row.update(complexity=20, covered_lines=96, executable_lines=137)
        self.baseline['platforms']['mac']['high_risk'][row['id']] = copy.deepcopy(row)
        self.baseline['platforms']['mac']['high_risk'][row['id']]['reason'] = 'Fixture ceiling'
        self.assertEqual(METRICS.gate(report, self.baseline), [])
        before = float(METRICS.risk(row))
        row.update(covered_lines=96 * 10 ** 10 - 1, executable_lines=137 * 10 ** 10)
        self.assertEqual(f'{before:.4f}', f'{float(METRICS.risk(row)):.4f}')
        self.assertIn('Baseline risk increased', METRICS.gate(report, self.baseline)[0])

    def test_score_of_exactly_30_is_allowed(self):
        report = self.measure()
        report['functions'][0].update(complexity=5, covered_lines=0, executable_lines=8)
        self.assertEqual(METRICS.risk(report['functions'][0]), 30)
        self.assertEqual(METRICS.gate(report, self.baseline), [])

    def test_high_risk_baseline_requires_reason(self):
        report = self.measure()
        row = report['functions'][0]
        self.baseline['platforms']['mac']['high_risk'][row['id']] = copy.deepcopy(row)
        self.assertEqual(
            METRICS.gate(report, self.baseline),
            ['Baseline high-risk declaration needs a reason: ' + row['id']],
        )

    def test_missing_coverage_never_means_covered(self):
        self.target['files'][0]['functions'] = []
        report = self.measure()
        self.assertEqual(report['functions'][0]['status'], 'unmatched')
        self.assertNotIn('coverage', report['functions'][0])
        self.assertIn('Unmatched production', METRICS.gate(report, self.baseline)[0])

    def test_duplicate_declarations_fail_instead_of_choosing_one(self):
        self.target['files'][0]['functions'].append(copy.deepcopy(self.function))
        self.assertEqual(self.measure()['functions'][0]['status'], 'unmatched')

    def test_duplicate_declaration_identity_fails(self):
        report = self.measure(declarations=[self.declaration, copy.deepcopy(self.declaration)])
        expected = 'Duplicate declaration identity: Example.swift::.func uncovered ( _ value : Int )'
        self.assertIn(expected, METRICS.gate(report, self.baseline))

    def test_duplicate_coverage_target_identity_is_malformed(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate coverage target identity'):
            self.measure(targets=[self.target, copy.deepcopy(self.target)])

    def test_duplicate_complexity_identity_is_malformed(self):
        self.complexity.append(copy.deepcopy(self.complexity[0]))
        with self.assertRaisesRegex(ValueError, 'Duplicate complexity at'):
            self.measure()

    def test_malformed_complexity_evidence_fails(self):
        self.complexity[0]['reason'] = 'Unexpected SwiftLint output'
        with self.assertRaisesRegex(ValueError, 'Malformed SwiftLint complexity evidence'):
            self.measure()

    def test_source_root_file_missing_from_project_sources_fails(self):
        with self.assertRaisesRegex(ValueError, 'Production source missing from project Sources'):
            METRICS.validate_source_inventory(
                {'Example.swift', 'Forgotten.swift'}, {'Example.swift'}
            )

    def test_project_source_missing_from_inventory_roots_fails(self):
        with self.assertRaisesRegex(ValueError, 'Production project source outside inventory roots'):
            METRICS.validate_source_inventory(
                {'Example.swift'}, {'Example.swift', 'Outside.swift'}
            )

    def test_xccov_path_from_another_worktree_matches_known_source(self):
        (self.root / 'CodexBarMac').mkdir()
        (self.root / 'CodexBarMac/Portable.swift').write_text('func portable() {}')
        path = '/tmp/old-checkout/CodexBarMac/Portable.swift'
        self.assertEqual(
            METRICS.relative(path, {'CodexBarMac/Portable.swift'}),
            'CodexBarMac/Portable.swift',
        )

    def test_missing_required_target_fails_with_evidence(self):
        self.target["name"] = "Other.app"
        report = self.measure()
        self.assertIn("Missing coverage target Example.app", report["errors"])
        self.assertTrue(METRICS.gate(report, self.baseline))

    def test_zero_executable_lines_fail(self):
        self.function['executableLines'] = 0
        self.assertEqual(self.measure()['functions'][0]['status'], 'unmatched')

    def test_malformed_target_and_file_aggregate_counts_fail(self):
        for item, covered, executable in [
            (self.target, 999, 1),
            (self.target['files'][0], -9, -1),
            (self.target, True, 8),
        ]:
            with self.subTest(item=item, covered=covered, executable=executable):
                original = item['coveredLines'], item['executableLines']
                item['coveredLines'], item['executableLines'] = covered, executable
                with self.assertRaisesRegex(ValueError, 'Invalid xccov counts'):
                    self.measure()
                item['coveredLines'], item['executableLines'] = original

    def test_missing_complexity_fails_even_with_full_coverage(self):
        self.complexity = []
        self.function['coveredLines'] = 8
        self.assertEqual(self.measure()['functions'][0]['status'], 'unmatched')

    def test_other_platform_never_supplies_coverage(self):
        incidental = copy.deepcopy(self.target)
        incidental['name'] = 'Watch.app'
        incidental['files'][0]['functions'][0]['coveredLines'] = 8
        report = self.measure(targets=[self.target, incidental])
        self.assertEqual(report['functions'][0]['covered_lines'], 0)
        self.assertEqual(report['excluded_coverage'][0]['target'], 'Watch.app')

    def test_source_hash_exception_invalidates_after_change(self):
        self.target['files'][0]['functions'] = []
        report = self.measure()
        row = report['functions'][0]
        self.baseline['platforms']['mac']['unmatched'][row['id']] = dict(source_sha256=row['source_sha256'], complexity=6, reason='Fixture unavailable on this platform')
        self.assertEqual(METRICS.gate(report, self.baseline), [])
        (self.root / 'Example.swift').write_text('func uncovered(_ value: Int) { fatalError() }')
        self.assertEqual(METRICS.gate(self.measure(), self.baseline), [
            'Unmatched production declaration needs reviewed evidence: ' + row['id'],
        ])

    def test_unmatched_exception_requires_measured_numeric_complexity(self):
        self.complexity = []
        self.target['files'][0]['functions'] = []
        report = self.measure()
        row = report['functions'][0]
        self.baseline['platforms']['mac']['unmatched'][row['id']] = dict(
            source_sha256=row['source_sha256'],
            complexity=None,
            reason='Fixture must not waive missing complexity evidence',
        )
        self.assertEqual(METRICS.gate(report, self.baseline), [
            'Unmatched production declaration needs reviewed evidence: ' + row['id'],
        ])

    def test_removed_high_risk_symbol_requires_baseline_review(self):
        self.baseline['platforms']['mac']['high_risk']['deleted'] = dict(complexity=6, covered_lines=0, executable_lines=8)
        self.assertTrue(any('disappeared' in error for error in METRICS.gate(self.measure(), self.baseline)))

    def test_invalid_counts_are_rejected(self):
        for covered, executable in [(9, 8), (-1, 8), (0, 0), (True, 8)]:
            with self.assertRaises(ValueError):
                METRICS.score(6, covered, executable)
        self.assertEqual(METRICS.score(6, 4, 8), Fraction(21, 2))

    def test_line_shift_preserves_baseline_identity(self):
        before = self.measure()['functions'][0]['id']
        self.declaration.update(line=2, bodyLine=2, endLine=9, lintLine=2)
        self.complexity[0]['line'] = 2
        self.function['lineNumber'] = 2
        self.assertEqual(self.measure()['functions'][0]['id'], before)

    def test_accessors_and_closures_stay_visible_without_fake_complexity(self):
        self.target['files'][0]['functions'].append(dict(self.function, name='closure #1 in uncovered(_:)'))
        self.target['files'][0]['functions'].append(dict(self.function, name='Example.body.getter'))
        report = self.measure()
        self.assertEqual(len(report['excluded_coverage']), 2)
        self.assertEqual(report['functions'][0]['complexity'], 6)
        self.assertIsNone(METRICS.unmeasured_kind('Example.readSecret(account:)'))

    def test_known_deinitializer_variants_are_excluded_with_a_bounded_reason(self):
        self.target['files'][0]['functions'] += [
            dict(self.function, name='Example.deinit'),
            dict(self.function, name='Example.__deallocating_deinit'),
        ]
        report = self.measure()
        deinitializers = [
            item for item in report['excluded_coverage']
            if item['name'].endswith('deinit')
        ]
        self.assertEqual(len(deinitializers), 2)
        self.assertTrue(all(item['reason'].startswith('Deinitializer:') for item in deinitializers))
        self.assertEqual(report['errors'], [])

    def test_unclassified_production_xccov_declaration_fails_closed(self):
        self.target['files'][0]['functions'].append(
            dict(self.function, name='Example.mystery()', lineNumber=2)
        )
        report = self.measure()
        self.assertIn(
            'Unrecognized unjoined xccov production declaration: Example.swift:2 Example.mystery()',
            METRICS.gate(report, self.baseline),
        )
        mystery = next(
            item for item in report['excluded_coverage']
            if item['name'] == 'Example.mystery()'
        )
        self.assertIn('Unrecognized unjoined', mystery['reason'])

    def test_markdown_uses_reported_complexity_basis(self):
        report = self.measure()
        self.assertIn('SwiftLint fixture-version decision count', METRICS.markdown(report))

    def test_type_error_writes_failure_artifact(self):
        output = self.root / 'failure-artifact'
        arguments = [
            'measure.py', '--result', str(self.root / 'result.xcresult'),
            '--output', str(output),
        ]
        with patch.object(METRICS, 'collect', side_effect=TypeError('bad xccov type')):
            with patch.object(sys, 'argv', arguments):
                self.assertEqual(METRICS.main(), 1)
        self.assertEqual((output / 'failure.txt').read_text(), 'bad xccov type\n')


if __name__ == '__main__':
    unittest.main()
