#!/usr/bin/env python3
"""Independent schema validation: python3 -m pip install jsonschema (optional dev tool)."""
import json, pathlib, sys
try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    sys.exit('Install optional dev dependency: python3 -m pip install jsonschema')
root = pathlib.Path(__file__).resolve().parents[1]
schema = json.loads((root/'schemas/content-filter.schema.json').read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema, format_checker=FormatChecker())
for path in sys.argv[1:] or [str(root/'rules/example-fiction.json')]:
    validator.validate(json.loads(pathlib.Path(path).read_text()))
    print(f'VALID: {path}')
