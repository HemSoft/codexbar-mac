#!/usr/bin/env python3
"""Collect exact Mac function line risk and fail closed on missing evidence."""
import argparse
from collections import defaultdict
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / 'scripts/function-risk/policy.json'
BASELINE = ROOT / 'scripts/function-risk/baseline.json'


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def run(command, **kwargs):
    return subprocess.check_output(command, text=True, cwd=ROOT, **kwargs).strip()


def score(complexity, covered, executable):
    if type(complexity) is not int or complexity < 0:
        raise ValueError('Invalid complexity')
    if type(covered) is not int or type(executable) is not int or not 0 <= covered <= executable or executable <= 0:
        raise ValueError('Invalid covered/executable line counts')
    return complexity ** 2 * (1 - Fraction(covered, executable)) ** 3 + complexity


def risk(row):
    return score(row['complexity'], row['covered_lines'], row['executable_lines'])


def relative(path, expected_paths=None):
    resolved = Path(path).resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        # Xccov records absolute checkout paths. Accept the longest suffix that
        # names the same file in this worktree so archived CI evidence remains portable.
        matches = []
        for expected in expected_paths or []:
            parts = Path(expected).parts
            if tuple(resolved.parts[-len(parts):]) == parts and (ROOT / expected).is_file():
                matches.append(expected)
        if len(matches) == 1:
            return matches[0]
        raise


def project_sources(project, targets):
    """Read actual PBX Sources membership instead of assuming directory membership."""
    objects = project['objects']
    paths = {}

    def walk(identifier, parent):
        item = objects[identifier]
        path = parent / item.get('path', '')
        if item['isa'] == 'PBXFileReference':
            paths[identifier] = str(path)
        for child in item.get('children', []):
            walk(child, path)

    walk(objects[project['rootObject']]['mainGroup'], Path())
    output = set()
    found = set()
    for target in objects.values():
        if target.get('isa') != 'PBXNativeTarget' or target.get('name') not in targets:
            continue
        found.add(target['name'])
        for phase in target['buildPhases']:
            if objects[phase]['isa'] == 'PBXSourcesBuildPhase':
                for identifier in objects[phase]['files']:
                    path = paths[objects[identifier]['fileRef']]
                    if path.endswith('.swift'):
                        output.add(path)
    if found != set(targets):
        raise ValueError(f'Missing project targets: {set(targets) - found}')
    return output


def validate_source_inventory(files, source_paths):
    """Require source roots and the Xcode production Sources phase to agree."""
    files = set(files)
    missing_from_inventory = source_paths - files
    missing_from_project = files - source_paths
    if missing_from_inventory:
        raise ValueError(
            f'Production project source outside inventory roots: {sorted(missing_from_inventory)}'
        )
    if missing_from_project:
        raise ValueError(
            f'Production source missing from project Sources: {sorted(missing_from_project)}'
        )


def validate_coverage_counts(label, item):
    covered = item.get('coveredLines')
    executable = item.get('executableLines')
    if (
        type(covered) is not int
        or type(executable) is not int
        or covered < 0
        or executable < 0
        or covered > executable
    ):
        raise ValueError(
            f'Invalid xccov counts for {label}: coveredLines={covered!r}, '
            f'executableLines={executable!r}'
        )


def unmeasured_kind(name):
    if 'closure #' in name:
        return 'Closure: SwiftLint includes its decisions in the enclosing func/init when present; no independent score.'
    if name.startswith('variable initialization expression'):
        return 'Stored-property initialization: outside SwiftLint func/init complexity scope.'
    if re.search(r'\.(getter|setter|modify|read)$', name):
        return 'Accessor: outside SwiftLint func/init complexity scope.'
    if name.endswith('.deinit') or name.endswith('.__deallocating_deinit'):
        return 'Deinitializer: outside SwiftLint func/init complexity scope.'
    return None


def measure(platform, declarations, complexity, coverage, source_paths, policy):
    settings = policy['platforms'][platform]
    errors = []
    exclusions = []
    decisions = {}
    for item in complexity:
        if item['rule_id'] != 'cyclomatic_complexity':
            raise ValueError('Unexpected measurement rule')
        location = (relative(item['file']), item['line'], item['character'])
        if location in decisions:
            raise ValueError(f'Duplicate complexity at {location}')
        match = re.search(r'currently complexity is (\d+)$', item['reason'])
        if match is None:
            raise ValueError(f'Malformed SwiftLint complexity evidence at {location}')
        decisions[location] = int(match[1])
    functions = defaultdict(list)
    target_names = [target['name'] for target in coverage['targets']]
    if len(set(target_names)) != len(target_names):
        raise ValueError('Duplicate coverage target identity')
    targets = {target['name']: target for target in coverage['targets']}
    for name in settings['coverage_targets']:
        if name not in targets:
            errors.append(f'Missing coverage target {name}')
            continue
        target = targets[name]
        validate_coverage_counts(f'target {name}', target)
        if target['executableLines'] <= 0:
            errors.append(f'Empty coverage target {name}')
        for file in target['files']:
            validate_coverage_counts(f"file {file.get('path')!r} in target {name}", file)
            try:
                path = relative(file['path'], source_paths)
            except ValueError:
                exclusions.append(dict(target=name, path=file['path'], reason='Generated or external source outside checkout.', functions=file['functions']))
                continue
            if path not in source_paths:
                exclusions.append(dict(target=name, path=path, reason='Test source or source outside this platform production Sources phases.', functions=file['functions']))
                continue
            for function in file['functions']:
                validate_coverage_counts(
                    f"function {function.get('name')!r} in {file.get('path')!r}",
                    function,
                )
                functions[path].append(dict(function, target=name))
    for name, target in targets.items():
        if name not in settings['coverage_targets']:
            exclusions.append(dict(target=name, reason='Incidental embedded product; use its own platform suite.', files=target['files']))

    rows = []
    declaration_ids = set()
    consumed = set()
    for declaration in declarations:
        path = declaration['path']
        if path not in source_paths:
            continue
        row = dict(declaration, platform=platform)
        key = path + '::' + declaration['symbol']
        if key in declaration_ids:
            errors.append(f'Duplicate declaration identity: {key}')
        declaration_ids.add(key)
        row['id'] = key
        location = (path, declaration['lintLine'], declaration['lintColumn'])
        row['complexity'] = decisions.pop(location, None)
        row['source_sha256'] = hashlib.sha256('\n'.join((ROOT / path).read_text().splitlines()[declaration['line'] - 1:declaration['endLine']]).encode()).hexdigest()
        candidates = [f for f in functions[path] if not unmeasured_kind(f['name']) and declaration['line'] <= f['lineNumber'] <= declaration['bodyLine']]
        # Keep independently compiled counters separate. The app owns shared code;
        # widget-only source uses the widget target. Never take the highest coverage.
        for target in settings['coverage_targets']:
            preferred = [f for f in candidates if f['target'] == target]
            if preferred:
                candidates = preferred
                break
        if row['complexity'] is None:
            row.update(status='unmatched', reason='No unique SwiftLint complexity measurement.')
        elif len(candidates) != 1:
            row.update(status='unmatched', reason=f'Expected one xccov declaration, found {len(candidates)}.')
        elif candidates[0]['executableLines'] <= 0:
            row.update(status='unmatched', reason='xccov declaration has no executable lines.')
        else:
            function = candidates[0]
            consumed.add((path, function['target'], function['lineNumber'], function['name']))
            row.update(target=function['target'], coverage_symbol=function['name'], covered_lines=function['coveredLines'], executable_lines=function['executableLines'], status='scored')
            value = risk(row)
            row.update(coverage=float(Fraction(row['covered_lines'], row['executable_lines'])), crap=float(value), crap_exact=f'{value.numerator}/{value.denominator}')
        reason = policy['excluded_files'].get(path) or policy['excluded_symbols'].get(key)
        if reason:
            row.update(status='excluded', reason=reason)
        rows.append(row)
    if not rows:
        errors.append('No production declarations measured')
    for path in source_paths:
        if not any(d['path'] == path for d in declarations):
            exclusions.append(dict(path=path, reason='Source has no func/init bodies; accessors, closures and synthesized declarations have no SwiftLint score.'))
    for location in decisions:
        if location[0] in source_paths:
            errors.append(f'SwiftLint declaration missing from source inventory: {location}')
    for path, file_functions in functions.items():
        for function in file_functions:
            identifier = (path, function['target'], function['lineNumber'], function['name'])
            if identifier not in consumed:
                reason = unmeasured_kind(function['name'])
                if not reason:
                    reason = 'Unrecognized unjoined xccov production declaration; no complexity assigned.'
                    errors.append(
                        f"Unrecognized unjoined xccov production declaration: "
                        f"{path}:{function['lineNumber']} {function['name']}"
                    )
                exclusions.append(dict(path=path, reason=reason, **function))
    complexity_basis = f"SwiftLint {policy['tools']['swiftlint']} decision count, starts at zero"
    return dict(schema=1, platform=platform, coverage_basis='xccov function executable-line coverage', complexity_basis=complexity_basis, functions=rows, excluded_coverage=exclusions, errors=errors)


def gate(report, baseline):
    errors = list(report['errors'])
    old = baseline['platforms'].get(report['platform'])
    if old is None:
        return errors + ['Missing platform baseline']
    high = old['high_risk']
    unmatched = old['unmatched']
    seen_high, seen_unmatched = set(), set()
    for row in report['functions']:
        identifier = row['id']
        if row['status'] == 'excluded':
            continue
        if row['status'] == 'unmatched':
            prior = unmatched.get(identifier)
            if (
                type(row['complexity']) is not int
                or not prior
                or not prior.get('reason')
                or prior.get('source_sha256') != row['source_sha256']
                or prior.get('complexity') != row['complexity']
            ):
                errors.append(f'Unmatched production declaration needs reviewed evidence: {identifier}')
            if prior:
                seen_unmatched.add(identifier)
            continue
        value = risk(row)
        if identifier in high:
            seen_high.add(identifier)
            if not high[identifier].get('reason'):
                errors.append(f'Baseline high-risk declaration needs a reason: {identifier}')
            elif value > risk(high[identifier]):
                errors.append(f'Baseline risk increased: {identifier}')
        elif value > 30:
            errors.append(f'New production risk above 30: {identifier}')
    for identifier in high.keys() - seen_high:
        errors.append(f'Baseline high-risk declaration disappeared or lost measurement; review baseline: {identifier}')
    for identifier in unmatched.keys() - seen_unmatched:
        errors.append(f'Stale unmatched exception; remove from baseline: {identifier}')
    return errors


def markdown(report):
    scored = [r for r in report['functions'] if r['status'] == 'scored']
    queue = sorted((r for r in scored if risk(r) >= 15), key=lambda r: (-risk(r), r['id']))
    lines = [f"# {report['platform']} function risk", '', f"{len(scored)} scored declarations; {sum(r['status'] == 'unmatched' for r in report['functions'])} unmatched; {sum(r['status'] == 'excluded' for r in report['functions'])} excluded source declarations.", '', f"Function executable-line coverage; {report['complexity_basis']}. JSON contains the complete declaration and exclusion inventory, exact fractions, source hashes and tool versions.", '', 'Scores 15 through 30 form the review queue. Existing scores above 30 remain visible and may not exceed their baseline ceiling.', '', '| CRAP | Decisions | Coverage | Covered / executable lines | Target | Declaration |', '| ---: | ---: | ---: | ---: | --- | --- |']
    for row in queue:
        coverage = 100 * float(Fraction(row['covered_lines'], row['executable_lines']))
        lines.append(f"| {row['crap']:.4f} | {row['complexity']} | {coverage:.2f}% | {row['covered_lines']} / {row['executable_lines']} | {row['target']} | {row['path']}:{row['line']} `{row['symbol']}` |")
    lines += ['', '## Gate', ''] + (['- ' + error for error in report['errors']] or ['Passed.'])
    return '\n'.join(lines) + '\n'


def collect(args):
    policy = read(POLICY)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    version = run(['xcodebuild', '-version'])
    if version != policy['tools']['xcode']:
        raise ValueError(f"Expected {policy['tools']['xcode']!r}, found {version!r}; review the tool pin and baseline together.")
    lint = args.swiftlint
    if run([lint, 'version']) != policy['tools']['swiftlint']:
        raise ValueError('SwiftLint version differs from measurement pin')
    host = Path(run(['xcrun', '--find', 'swiftc'])).parent.parent / 'lib/swift/host'
    inventory = output / 'declarations-tool'
    run(['xcrun', 'swiftc', '-I', str(host), '-L', str(host), '-Xlinker', '-rpath', '-Xlinker', str(host), '-lSwiftSyntax', '-lSwiftParser', 'scripts/function-risk/declarations.swift', '-o', str(inventory)])
    files = sorted(str(f.relative_to(ROOT)) for directory in policy['source_roots'] for f in (ROOT / directory).rglob('*.swift'))
    declarations = json.loads(run([str(inventory), *files]))
    inventory.unlink()
    complexity = json.loads(run([lint, 'lint', '--config', 'scripts/function-risk/complexity.yml', '--reporter', 'json', '--quiet', '--no-cache', *policy['source_roots']]))
    coverage = json.loads(run(['xcrun', 'xccov', 'view', '--report', '--json', str(args.result.resolve())]))
    project = json.loads(run(['plutil', '-convert', 'json', '-o', '-', 'CodexBarMac.xcodeproj/project.pbxproj']))
    source_paths = project_sources(project, policy['platforms'][args.platform]['source_targets'])
    validate_source_inventory(files, source_paths)
    write(output / 'declarations.json', declarations)
    write(output / 'complexity.json', complexity)
    write(output / 'coverage.json', coverage)
    write(output / 'policy.json', policy)
    write(output / 'baseline.json', read(args.baseline))
    write(output / 'test-summary.json', json.loads(run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(args.result.resolve())])))
    report = measure(args.platform, declarations, complexity, coverage, source_paths, policy)
    report['tools'] = dict(policy['tools'], swift=run(['xcrun', 'swift', '--version']), python=sys.version, revision=run(['git', 'rev-parse', 'HEAD']), policy_sha256=hashlib.sha256(POLICY.read_bytes()).hexdigest(), baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest())
    baseline = read(args.baseline)
    report['errors'] = gate(report, baseline)
    for row in report['functions']:
        exception = baseline['platforms'].get(args.platform, {}).get('unmatched', {}).get(row['id'])
        if row['status'] == 'unmatched' and exception:
            row['baseline_exception'] = exception
    write(output / 'report.json', report)
    (output / 'report.md').write_text(markdown(report))
    print(markdown(report))
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(markdown(report))
    return bool(report['errors'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', default='mac', choices=['mac'])
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, default=BASELINE)
    parser.add_argument('--swiftlint', default=os.environ.get('FUNCTION_RISK_SWIFTLINT', 'swiftlint'))
    args = parser.parse_args()
    try:
        return collect(args)
    except (ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError) as error:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'failure.txt').write_text(str(error) + '\n')
        print(f'Function risk measurement failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
