#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Measure the actual stream redactor with synthetic data; no UI or credentials."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = r'''
import Foundation
enum ModelError: Error { case invalid(String) }
@main struct Benchmark {
    static func main() throws {
        var results = [[String: Any]]()
        for (name, secret, input) in [
            ("ordinary", "synthetic-private-input", Data(String(repeating: "user@host: synthetic output 0123456789\n", count: 20_000).utf8)),
            ("repeated-prefix", String(repeating: "a", count: 4095) + "b", Data((String(repeating: "a", count: 65_536) + "|").utf8))
        ] {
            var samples = [Double]()
            for _ in 0..<5 {
                var redactor = AgentRedactor(); try redactor.add(secret)
                let start = ProcessInfo.processInfo.systemUptime
                var output = Data()
                for offset in stride(from: 0, to: input.count, by: 4096) {
                    output.append(redactor.consume(input.subdata(in: offset..<min(input.count, offset + 4096))))
                }
                output.append(redactor.finish())
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                guard output == input else { throw ModelError.invalid("Benchmark altered non-secret output") }
            }
            results.append(["scenario": name, "bytes": input.count, "median_ms": samples.sorted()[2], "samples_ms": samples])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT/'Sources/OShellCore/AgentRedactor.swift')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='oshell-redaction-bench-') as directory:
        work = Path(directory)
        source = work/'fixture.swift'
        source.write_text(args.source.read_text() + '\n' + FIXTURE)
        binary = work/'benchmark'
        subprocess.run(['swiftc', '-O', '-parse-as-library', '-module-cache-path', str(work/'modules'),
                        str(source), '-o', str(binary)], check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == '__main__':
    main()
