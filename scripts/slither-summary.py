#!/usr/bin/env python3
"""Generate Slither summary reports (Markdown and HTML) from JSON output."""

import json
import sys
import os
from datetime import datetime

def get_severity_color(severity):
    """Return color for severity level."""
    colors = {
        'High': '#dc3545',
        'Medium': '#fd7e14',
        'Low': '#ffc107',
        'Informational': '#17a2b8'
    }
    return colors.get(severity, '#6c757d')

def generate_html_report(counts, by_detector, output_dir):
    """Generate a styled HTML report."""
    html_path = os.path.join(output_dir, 'slither-report.html')

    with open(html_path, 'w') as html:
        html.write('''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Slither Static Analysis Report</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif; line-height: 1.6; color: #333; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        h1 { color: #1a1a1a; margin-bottom: 10px; }
        .timestamp { color: #666; font-size: 14px; margin-bottom: 30px; }
        .summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin-bottom: 30px; }
        .card { background: white; border-radius: 8px; padding: 20px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .card-value { font-size: 36px; font-weight: bold; }
        .card-label { color: #666; font-size: 14px; text-transform: uppercase; }
        .severity-section { background: white; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); overflow: hidden; }
        .severity-header { padding: 15px 20px; color: white; font-weight: bold; font-size: 18px; }
        .detector-group { border-bottom: 1px solid #eee; }
        .detector-header { padding: 15px 20px; background: #f8f9fa; cursor: pointer; display: flex; justify-content: space-between; align-items: center; }
        .detector-header:hover { background: #e9ecef; }
        .detector-name { font-weight: 600; }
        .detector-count { background: #6c757d; color: white; padding: 2px 10px; border-radius: 12px; font-size: 12px; }
        .findings-list { padding: 0 20px 15px; display: none; }
        .findings-list.show { display: block; }
        .finding { background: #f8f9fa; border-radius: 4px; padding: 12px; margin-top: 10px; font-family: 'Monaco', 'Menlo', monospace; font-size: 13px; white-space: pre-wrap; word-break: break-word; border-left: 3px solid #dee2e6; }
        .no-findings { padding: 40px; text-align: center; color: #666; }
        .toggle-icon { transition: transform 0.2s; }
        .toggle-icon.open { transform: rotate(90deg); }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔍 Slither Static Analysis Report</h1>
''')
        html.write(f'        <p class="timestamp">Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>\n')

        # Summary cards
        html.write('        <div class="summary-cards">\n')
        for severity in ['High', 'Medium', 'Low', 'Informational']:
            color = get_severity_color(severity)
            html.write(f'''            <div class="card">
                <div class="card-value" style="color: {color}">{counts[severity]}</div>
                <div class="card-label">{severity}</div>
            </div>
''')
        total = sum(counts.values())
        html.write(f'''            <div class="card">
                <div class="card-value">{total}</div>
                <div class="card-label">Total</div>
            </div>
        </div>
''')

        # Findings by severity
        for severity in ['High', 'Medium', 'Low', 'Informational']:
            findings = [(k, v) for k, v in by_detector.items() if v['impact'] == severity]
            if not findings:
                continue

            color = get_severity_color(severity)
            html.write(f'''        <div class="severity-section">
            <div class="severity-header" style="background: {color}">{severity} Severity ({counts[severity]} findings)</div>
''')

            for detector, info in sorted(findings, key=lambda x: -x[1]['count']):
                detector_id = detector.replace('-', '_')
                html.write(f'''            <div class="detector-group">
                <div class="detector-header" onclick="toggleFindings('{detector_id}')">
                    <span class="detector-name"><span class="toggle-icon" id="icon_{detector_id}">▶</span> {detector}</span>
                    <span class="detector-count">{info['count']}</span>
                </div>
                <div class="findings-list" id="findings_{detector_id}">
''')
                for i, f in enumerate(info['findings']):
                    desc = f.get('description', 'No description').replace('<', '&lt;').replace('>', '&gt;')
                    html.write(f'                    <div class="finding">{desc}</div>\n')
                html.write('                </div>\n            </div>\n')

            html.write('        </div>\n')

        # JavaScript for toggling
        html.write('''        <script>
            function toggleFindings(id) {
                const findings = document.getElementById('findings_' + id);
                const icon = document.getElementById('icon_' + id);
                findings.classList.toggle('show');
                icon.classList.toggle('open');
            }
        </script>
    </div>
</body>
</html>
''')

    return html_path

def main():
    report_path = sys.argv[1] if len(sys.argv) > 1 else 'slither-reports/slither-report.json'
    output_dir = os.path.dirname(report_path) or '.'

    if not os.path.exists(report_path):
        print(f"Report not found: {report_path}")
        return 1

    with open(report_path, 'r') as f:
        data = json.load(f)

    results = data.get('results', {}).get('detectors', [])
    counts = {'High': 0, 'Medium': 0, 'Low': 0, 'Informational': 0}
    by_detector = {}

    for r in results:
        impact = r.get('impact', 'Unknown')
        check = r.get('check', 'unknown')
        if impact in counts:
            counts[impact] += 1
        if check not in by_detector:
            by_detector[check] = {'count': 0, 'impact': impact, 'findings': []}
        by_detector[check]['count'] += 1
        by_detector[check]['findings'].append(r)

    # Print summary to console
    print("=" * 50)
    print("         SLITHER FINDINGS SUMMARY")
    print("=" * 50)
    print(f"  High:          {counts['High']}")
    print(f"  Medium:        {counts['Medium']}")
    print(f"  Low:           {counts['Low']}")
    print(f"  Informational: {counts['Informational']}")
    print(f"  Total:         {sum(counts.values())}")
    print("=" * 50)

    if counts['High'] > 0:
        print("\n  ⚠️  WARNING: High severity findings detected!")
        print("  Review the slither-report.html artifact for details.\n")

    # Generate markdown report
    md_path = os.path.join(output_dir, 'slither-summary.md')
    with open(md_path, 'w') as md:
        md.write("# Slither Static Analysis Report\n\n")
        md.write("## Summary\n\n")
        md.write("| Severity | Count |\n")
        md.write("|----------|-------|\n")
        md.write(f"| 🔴 High | {counts['High']} |\n")
        md.write(f"| 🟠 Medium | {counts['Medium']} |\n")
        md.write(f"| 🟡 Low | {counts['Low']} |\n")
        md.write(f"| 🔵 Informational | {counts['Informational']} |\n")
        md.write(f"| **Total** | **{sum(counts.values())}** |\n\n")

        for severity in ['High', 'Medium', 'Low']:
            findings = [(k, v) for k, v in by_detector.items() if v['impact'] == severity]
            if findings:
                md.write(f"## {severity} Severity Findings\n\n")
                for detector, info in sorted(findings, key=lambda x: -x[1]['count']):
                    md.write(f"### {detector} ({info['count']} findings)\n\n")
                    for i, f in enumerate(info['findings'][:3]):
                        desc = f.get('description', 'No description')
                        if len(desc) > 300:
                            desc = desc[:300] + "..."
                        md.write(f"**Finding {i+1}:**\n```\n{desc}\n```\n\n")
                    if len(info['findings']) > 3:
                        md.write(f"*... and {len(info['findings']) - 3} more*\n\n")

    print(f"Markdown report generated: {md_path}")

    # Generate HTML report
    html_path = generate_html_report(counts, by_detector, output_dir)
    print(f"HTML report generated: {html_path}")

    return 0

if __name__ == '__main__':
    sys.exit(main())
