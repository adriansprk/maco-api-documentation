#!/bin/bash
set -euo pipefail

# Definition der Eingabe- und Ausgabedateien
EVENTS_OPENAPI_YAML="events/events-openapi.yaml"
MALOIDENT_OPENAPI_YAML="maloident-macoapp/maloident-macoapp.yaml"
MALOIDENT_NB_YAML="maloident-netzbetreiber/maloident-netzbetreiber.yaml"
MALOIDENT_LF_YAML="maloident-lieferant/maloident-lieferant.yaml"
MACOAPP_TRIGGER_YAML="macoapp-trigger/macoapp-trigger.yaml"
MACOAPP_LESEN_YAML="macoapp-lesen/macoapp-lesen.yaml"
MACOAPP_SCHREIBEN_YAML="macoapp-schreiben/macoapp-schreiben.yaml"
OUTPUT_DIR="_build"
SCHEMAS_DIR="_schemas"
BO4E_COMPONENTS_YAML="${SCHEMAS_DIR}/bo4ecomponents.yml"
OPENAPI_SOURCE="../bo4e-schema/docs/openapi.yaml"
BO4E_PIN_FILE="../bo4e-schema/.git"
JSON_SCHEMA_META="${SCHEMAS_DIR}/json-schema-2020-12.json"
JSON_SCHEMA_META_URL="https://json-schema.org/draft/2020-12/schema"

# Erstellen der notwendigen Verzeichnisse
mkdir -p "$OUTPUT_DIR"
mkdir -p "$SCHEMAS_DIR"

# Copy BO4E from the exact workspace submodule pin, not floating origin/master.
OPENAPI_FILE="${SCHEMAS_DIR}/openapi.yml"
if [[ ! -f "$OPENAPI_SOURCE" || ! -e "$BO4E_PIN_FILE" ]]; then
  echo "BO4E schema checkout not found: $OPENAPI_SOURCE" >&2
  exit 1
fi

# Quote BO4E's external JSON Schema metaschema refs so YAML parses them as strings.
# The legacy resolver misreads unquoted URLs as nested objects and crashes in link.split.
python3 - "$OPENAPI_SOURCE" "$OPENAPI_FILE" <<'PYTHON'
import pathlib, sys
source, destination = map(pathlib.Path, sys.argv[1:])
text = source.read_text()
text = text.replace("$ref: https://json-schema.org/draft/2020-12/schema",
                    "$ref: 'https://json-schema.org/draft/2020-12/schema'")
destination.write_text(text)
PYTHON
curl --fail --silent --show-error --location "$JSON_SCHEMA_META_URL" --output "$JSON_SCHEMA_META"
jq -e 'type == "object" and has("$schema")' "$JSON_SCHEMA_META" >/dev/null

echo "OpenAPI source: $OPENAPI_SOURCE (pinned workspace checkout)"

# Build into a temporary directory; existing artifacts stay untouched until all succeed.
BUILD_TMP=$(mktemp -d "${OUTPUT_DIR}/.schema-build.XXXXXX")
trap 'rm -rf "$BUILD_TMP"' EXIT

build_and_format_openapi() {
  local input_yaml=$1
  local output_filename=$2
  local tmp_json="${BUILD_TMP}/${output_filename}.json"
  local tmp_yaml="${BUILD_TMP}/${output_filename}.yaml"
  local tmp_min="${BUILD_TMP}/${output_filename}.min.json"

  npx --yes @redocly/cli@2.57.0 bundle "$input_yaml" --output "$tmp_yaml"
  npx --yes @redocly/cli@2.57.0 bundle "$input_yaml" --output "$tmp_json"
  jq . "$tmp_json" > "$tmp_min"
  jq -e 'type == "object" and has("openapi") and has("components") and (.components | has("schemas"))' "$tmp_min" >/dev/null
}

# Verarbeiten jeder YAML-Datei
build_and_format_openapi "$MACOAPP_SCHREIBEN_YAML" "macoapp-schreiben"
build_and_format_openapi "$MACOAPP_TRIGGER_YAML" "macoapp-trigger"
build_and_format_openapi "$MACOAPP_LESEN_YAML" "macoapp-lesen"
build_and_format_openapi "$MALOIDENT_OPENAPI_YAML" "maloident-macoapp"
build_and_format_openapi "$MALOIDENT_NB_YAML" "maloident-netzbetreiber"
build_and_format_openapi "$MALOIDENT_LF_YAML" "maloident-lieferant"
build_and_format_openapi "$MACOAPP_TRIGGER_YAML" "events-openapi"
build_and_format_openapi "$MACOAPP_LESEN_YAML" "bo4e-openapi"

# Promote outputs only after all eight documents bundle and validate.
for output_filename in macoapp-schreiben macoapp-trigger macoapp-lesen maloident-macoapp maloident-netzbetreiber maloident-lieferant events-openapi bo4e-openapi; do
  for extension in yaml json min.json; do
    mv "${BUILD_TMP}/${output_filename}.${extension}" "${OUTPUT_DIR}/${output_filename}.${extension}"
  done
done
