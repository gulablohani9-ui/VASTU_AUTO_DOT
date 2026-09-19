#!/usr/bin/env bash
set -euo pipefail
if grep -RInF 'BoundaryMode.add' lib; then echo 'ERROR: ADD mode remains.'; exit 1; fi
if grep -RInF 'onAdd' lib; then echo 'ERROR: onAdd remains.'; exit 1; fi
if grep -RInF 'void addPoint' lib; then echo 'ERROR: addPoint remains.'; exit 1; fi
if grep -RInF 'canvas.drawColor(Colors.white);' lib; then echo 'ERROR: one-argument drawColor call remains.'; exit 1; fi
if grep -RInF 'Offset _polygonCenter()' lib; then echo 'ERROR: stale _polygonCenter helper remains.'; exit 1; fi
echo 'Source verification passed.'
