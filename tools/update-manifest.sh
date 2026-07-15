#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 8 ]; then
	PRODUCT="$1"
	CHANNEL="$2"
	BUILD_TAG="$3"
	RELEASE_TAG="$4"
	SOURCE_SHA="$5"
	ASSETS_DIR="$6"
	MANIFEST_PATH="$7"
	DISTRIBUTION_REPO="$8"
elif [ "$#" -ne 0 ]; then
	echo "Usage: $0 PRODUCT CHANNEL BUILD_TAG RELEASE_TAG SOURCE_SHA ASSETS_DIR MANIFEST_PATH DISTRIBUTION_REPO" >&2
	exit 1
fi

required=(PRODUCT CHANNEL BUILD_TAG RELEASE_TAG SOURCE_SHA ASSETS_DIR MANIFEST_PATH DISTRIBUTION_REPO)
for name in "${required[@]}"; do
	if [ -z "${!name:-}" ]; then
		echo "${name} is required" >&2
		exit 1
	fi
done

if [[ "${CHANNEL}" != "stable" && "${CHANNEL}" != "dev" ]]; then
	echo "CHANNEL must be stable or dev" >&2
	exit 1
fi

if [ ! -d "${ASSETS_DIR}" ]; then
	echo "ASSETS_DIR does not exist: ${ASSETS_DIR}" >&2
	exit 1
fi

for command in jq sha256sum; do
	command -v "${command}" >/dev/null 2>&1 || {
		echo "${command} is required" >&2
		exit 1
	}
done

max_builds="${MAX_BUILDS:-20}"
if ! [[ "${max_builds}" =~ ^[1-9][0-9]*$ ]]; then
	echo "MAX_BUILDS must be a positive integer" >&2
	exit 1
fi

mkdir -p "$(dirname "${MANIFEST_PATH}")"
assets_json='{}'
asset_count=0

while IFS= read -r -d '' asset; do
	name="$(basename "${asset}")"
	case "${name}" in
		*linux-amd64*) asset_key="linux-amd64" ;;
		*linux-arm64*) asset_key="linux-arm64" ;;
		*windows-amd64*) asset_key="windows-amd64" ;;
		*) continue ;;
	esac

	checksum_file="${asset}.sha256"
	if [ ! -f "${checksum_file}" ]; then
		echo "Checksum is missing for ${name}" >&2
		exit 1
	fi
	checksum="$(awk 'NR == 1 { print $1; exit }' "${checksum_file}")"
	if ! [[ "${checksum}" =~ ^[A-Fa-f0-9]{64}$ ]]; then
		echo "Invalid SHA-256 checksum for ${name}" >&2
		exit 1
	fi

	url="https://github.com/${DISTRIBUTION_REPO}/releases/download/${RELEASE_TAG}/${name}"
	assets_json="$(jq -c \
		--arg key "${asset_key}" \
		--arg name "${name}" \
		--arg url "${url}" \
		--arg sha256 "${checksum}" \
		'. + {($key): {name: $name, url: $url, sha256: $sha256}}' <<< "${assets_json}")"
	asset_count=$((asset_count + 1))
done < <(find "${ASSETS_DIR}" -maxdepth 1 -type f ! -name '*.sha256' -print0)

if [ "${asset_count}" -eq 0 ]; then
	echo "No supported binary assets were found in ${ASSETS_DIR}" >&2
	exit 1
fi

if [ -f "${MANIFEST_PATH}"; then
	existing="$(cat "${MANIFEST_PATH}")"
	jq -e . >/dev/null <<< "${existing}" || {
		echo "Invalid manifest JSON: ${MANIFEST_PATH}" >&2
		exit 1
	}
else
	existing='{}'
fi

updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
new_build="$(jq -cn \
	--arg tag "${BUILD_TAG}" \
	--arg release_tag "${RELEASE_TAG}" \
	--arg source_sha "${SOURCE_SHA}" \
	--arg created_at "${updated_at}" \
	--argjson assets "${assets_json}" \
	'{tag: $tag, release_tag: $release_tag, source_sha: $source_sha, created_at: $created_at, assets: $assets}')"

jq -n \
	--arg project "${PRODUCT}" \
	--arg channel "${CHANNEL}" \
	--arg updated_at "${updated_at}" \
	--argjson max_builds "${max_builds}" \
	--argjson existing "${existing}" \
	--argjson new_build "${new_build}" \
	'
		($existing | if type == "object" then . else {} end)
		| .schema_version = 1
		| .project = $project
		| .updated_at = $updated_at
		| .channels = (.channels // {})
		| .channels[$channel] = {
			latest: $new_build.tag,
			builds: (
				[$new_build]
				+ ((.channels[$channel].builds // []) | map(select(.tag != $new_build.tag)))
			)[0:$max_builds]
		}
	' > "${MANIFEST_PATH}"
