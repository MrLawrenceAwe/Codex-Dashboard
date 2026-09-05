#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift run CodexDashboard --export-preview-injection "$project_root/DashboardPreview/injection.js"
