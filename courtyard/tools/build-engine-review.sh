#!/usr/bin/env bash
set -euo pipefail

# Remote-only experiment. Never installs templates, exports the game, or deploys.
# --check-only is deliberately safe locally: no downloads, SDK setup or compiler.
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
patch_file="$project_dir/engine/patches/remove-ssao-depth-copy.patch"
source_guard="$project_dir/tests/ssao-depth-copy-check.js"
godot_tag='4.7.2-stable'
godot_revision='ed1daf0bf001b61586d9930840f2f1394092c079'
source_sha256='e954996374cbd1cb5d72e0e3781cc537408e6ce73b010b12c6c2f308a820690a'
emsdk_revision='5eb0bde7585670252e8ba05e9d361627bffd08b5'
emscripten_version='4.0.20'
emscripten_revision='c387d7a7e9537d0041d2c3ae71b7538cc978104e'
scons_version='4.9.1'
patch_sha256='beae0eea522dde438af7415393c0fe77f25486e7accf2a341658485ce1ec96cd'
source_file='drivers/gles3/rasterizer_scene_gles3.cpp'
original_cpp_sha256='6d0719c9cd2caf685a9825028183bdf058081d7bc92d4b27ed2587f39b081221'
patched_cpp_sha256='b09e9085788b45d9d3b8dab6052a1b1e9fc3132f713b90f613fcd010437717d4'
jobs="${ENGINE_REVIEW_JOBS:-2}"
flags=(platform=web target=template_release threads=no production=yes "-j$jobs")

fail() { echo "ENGINE_REVIEW: $*" >&2; exit 1; }
verify_hash() {
  local actual
  actual="$(sha256sum -- "$1")"
  [[ "${actual%% *}" == "$2" ]] || fail "Checksum mismatch: $1"
}
case "$jobs" in 2|4) ;; *) fail 'ENGINE_REVIEW_JOBS must be 2 or 4' ;; esac
case "$#:${1:-}" in 0:|1:--check-only) ;; *) fail 'Usage: bash courtyard/tools/build-engine-review.sh [--check-only]' ;; esac
[[ -f "$patch_file" && -f "$source_guard" ]] || fail 'Missing reviewed patch/source guard'
verify_hash "$patch_file" "$patch_sha256"
patch_targets="$(git apply --numstat "$patch_file" | cut -f3)"
[[ "$patch_targets" == "$source_file" ]] || fail 'Only the reviewed SSAO source file may be patched'
if [[ "${1:-}" == --check-only ]]; then
  printf 'ENGINE_REVIEW_CHECK: PASS; no downloads, setup, compiler or source mutation\nGodot: %s (%s)\nSource SHA256: %s\nEmscripten: %s; SCons: %s\nFlags:' "$godot_tag" "$godot_revision" "$source_sha256" "$emscripten_version" "$scons_version"
  printf ' %s' "${flags[@]}"
  printf '\nOutputs: RUNNER_TEMP/engine-review-artifacts; baseline then ONLY remove-ssao-depth-copy.patch\n'
  exit 0
fi

[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] ||
  fail 'Compilation is allowed only in a manually dispatched GitHub-hosted Linux workflow; use --check-only locally'
[[ -n "${RUNNER_TEMP:-}" && "$RUNNER_TEMP" == /* && -d "$RUNNER_TEMP" && "$RUNNER_TEMP" != / ]] || fail 'Missing isolated runner temporary directory'
for command in git curl tar gzip sha256sum zip unzip node python3; do
  command -v "$command" >/dev/null || fail "Missing runner dependency: $command"
done
artifact_dir="$RUNNER_TEMP/engine-review-artifacts"
[[ ! -e "$artifact_dir" ]] || fail 'Artifact directory already exists; refusing to overwrite a previous comparison'
mkdir -- "$artifact_dir"
work_dir="$(mktemp -d "$RUNNER_TEMP/engine-review-build-XXXXXX")"
download_dir="$RUNNER_TEMP/engine-review-downloads"
mkdir -p -- "$download_dir"
trap 'result=$?; printf "exit_code=%s\n" "$result" > "$artifact_dir/status.txt"' EXIT
run_logged() {
  local name="$1"
  shift
  "$@" 2>&1 | tee "$artifact_dir/$name.log"
}
printf 'Work: %s\nArtifacts: %s\n' "$work_dir" "$artifact_dir"
cp -- "$patch_file" "$artifact_dir/remove-ssao-depth-copy.patch"
# Retain the planned pins/flags even if downloading or compiling later fails.
printf 'Godot=%s\nGodot_revision=%s\nSource_SHA256=%s\nSDK_installer_revision=%s\nEmscripten=%s\nEmscripten_revision=%s\nSCons=%s\nFlags:' \
  "$godot_tag" "$godot_revision" "$source_sha256" "$emsdk_revision" "$emscripten_version" "$emscripten_revision" "$scons_version" > "$artifact_dir/build-plan.txt"
printf ' %s' "${flags[@]}" >> "$artifact_dir/build-plan.txt"
printf '\n' >> "$artifact_dir/build-plan.txt"

archive="$download_dir/godot-$godot_tag.tar.gz"
source_url="https://codeload.github.com/godotengine/godot/tar.gz/refs/tags/$godot_tag"
if [[ ! -f "$archive" ]]; then
  run_logged source-download curl --fail --location --retry 3 --connect-timeout 30 --max-time 600 "$source_url" --output "$archive.part"
  verify_hash "$archive.part" "$source_sha256"
  mv -- "$archive.part" "$archive"
fi
verify_hash "$archive" "$source_sha256"
# GitHub's tar PAX header records the exact source revision; no mutable tag-only
# checkout and no synthetic .git commit that would contaminate Godot versioning.
python3 - "$archive" "$godot_revision" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    assert archive.pax_headers.get('comment') == sys.argv[2], 'Unexpected Godot source revision'
PY
source_dir="$work_dir/godot"
mkdir -- "$source_dir"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"
verify_hash "$source_dir/$source_file" "$original_cpp_sha256"
cp -- "$source_dir/$source_file" "$artifact_dir/source-original.cpp"
run_logged source-guard-original node "$source_guard" --source "$source_dir"
grep -q '^SSAO_DEPTH_COPY_SOURCE_CHECK: PASS' "$artifact_dir/source-guard-original.log" || fail 'Source guard did not PASS (SKIP is not success)'

sdk_dir="$work_dir/emsdk"
git init --quiet "$sdk_dir"
git -C "$sdk_dir" remote add origin https://github.com/emscripten-core/emsdk.git
run_logged emsdk-fetch git -C "$sdk_dir" fetch --depth=1 origin "$emsdk_revision"
git -C "$sdk_dir" checkout --quiet --detach FETCH_HEAD
[[ "$(git -C "$sdk_dir" rev-parse HEAD)" == "$emsdk_revision" ]] || fail 'Unexpected SDK installer revision'
node - "$sdk_dir/emscripten-releases-tags.json" "$emscripten_version" "$emscripten_revision" <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const [file, version, revision] = process.argv.slice(2);
assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).releases[version], revision);
JS
export EMSDK_NOTTY=1 EMSDK_NUM_CORES="$jobs" PYTHONHASHSEED=0
run_logged emsdk-install "$sdk_dir/emsdk" install "$emscripten_version"
run_logged emsdk-activate "$sdk_dir/emsdk" activate "$emscripten_version"
# The SDK writes its configuration/cache inside this isolated installation.
source "$sdk_dir/emsdk_env.sh"
python3 -m venv "$work_dir/venv"
run_logged scons-install "$work_dir/venv/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "scons==$scons_version"
"$work_dir/venv/bin/python" -c 'import SCons,sys; assert SCons.__version__ == sys.argv[1]; print(SCons.__version__)' "$scons_version" > "$artifact_dir/scons-version.txt"
emcc --version > "$artifact_dir/emcc-version.txt"
grep -Eq '^emcc .* 4\.0\.20([[:space:]]|$)' "$artifact_dir/emcc-version.txt" || fail 'Unexpected Emscripten compiler'
python3 --version > "$artifact_dir/python-version.txt"
node --version > "$artifact_dir/node-version.txt"
unset SCONSFLAGS EMCC_CFLAGS CFLAGS CXXFLAGS LDFLAGS

template="$source_dir/bin/godot.web.template_release.wasm32.nothreads.zip"
preserve_template() {
  local label="$1" zip_file="$artifact_dir/$1-web-nothreads.zip"
  [[ -s "$template" ]] || fail 'Expected unthreaded release template was not produced'
  cp -- "$template" "$zip_file"
  unzip -tq "$zip_file" > "$artifact_dir/$label-zip-check.log"
  unzip -Z1 "$zip_file" | LC_ALL=C sort > "$artifact_dir/$label-zip-files.txt"
  [[ "$(grep -c '^godot.js$' "$artifact_dir/$label-zip-files.txt")" == 1 && "$(grep -c '^godot.wasm$' "$artifact_dir/$label-zip-files.txt")" == 1 ]] || fail 'Missing or duplicate paired JS/Wasm entries'
  unzip -p "$zip_file" godot.js | sha256sum > "$artifact_dir/$label-js.sha256"
  unzip -p "$zip_file" godot.wasm | sha256sum > "$artifact_dir/$label-wasm.sha256"
}

# Same source directory, environment, toolchain and flags. The second invocation
# retains baseline object files; only the reviewed CPP patch is applied.
cd -- "$source_dir"
run_logged baseline-build "$work_dir/venv/bin/scons" "${flags[@]}"
verify_hash "$source_dir/$source_file" "$original_cpp_sha256"
preserve_template baseline
git apply --check "$patch_file"
git apply "$patch_file"
verify_hash "$source_dir/$source_file" "$patched_cpp_sha256"
cp -- "$source_dir/$source_file" "$artifact_dir/source-patched.cpp"
# The Node guard intentionally admits pristine input only; its in-memory result
# is pinned above. Check the exact resulting CPP hash and reversible patch here.
git apply --reverse --check "$patch_file"
run_logged patched-build "$work_dir/venv/bin/scons" "${flags[@]}"
verify_hash "$source_dir/$source_file" "$patched_cpp_sha256"
preserve_template remove-ssao-depth-copy
cmp "$artifact_dir/baseline-zip-files.txt" "$artifact_dir/remove-ssao-depth-copy-zip-files.txt"
if cmp -s "$artifact_dir/baseline-wasm.sha256" "$artifact_dir/remove-ssao-depth-copy-wasm.sha256"; then
  fail 'Candidate Wasm is unchanged; do not claim the patch was compiled'
fi

cd -- "$artifact_dir"
sha256sum -- baseline-web-nothreads.zip remove-ssao-depth-copy-web-nothreads.zip remove-ssao-depth-copy.patch > SHA256SUMS
node - "$artifact_dir" "$godot_tag" "$godot_revision" "$source_url" "$source_sha256" "$emsdk_revision" "$emscripten_version" "$emscripten_revision" "$scons_version" "$original_cpp_sha256" "$patched_cpp_sha256" "${flags[@]}" <<'JS'
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const [dir, tag, revision, url, archive_sha256, emsdk_revision, emscripten, emscripten_revision, scons, original_cpp_sha256, patched_cpp_sha256, ...flags] = process.argv.slice(2);
const read = name => fs.readFileSync(path.join(dir, name), 'utf8').trim();
const hash = name => crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, name))).digest('hex');
const templates = ['baseline', 'remove-ssao-depth-copy'].map(name => ({name,
  zip: name + '-web-nothreads.zip', zip_sha256: hash(name + '-web-nothreads.zip'),
  js_sha256: read(name + '-js.sha256').split(/\s/)[0], wasm_sha256: read(name + '-wasm.sha256').split(/\s/)[0]}));
fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({
  repository_revision: process.env.GITHUB_SHA, workflow_run: process.env.GITHUB_RUN_ID,
  source: {tag, revision, url, archive_sha256, original_cpp_sha256, patched_cpp_sha256},
  patch: {file: 'remove-ssao-depth-copy.patch', sha256: hash('remove-ssao-depth-copy.patch')},
  toolchain: {emsdk_revision, emscripten, emscripten_revision, scons,
    compiler_version: read('emcc-version.txt'), python: read('python-version.txt'), node: read('node-version.txt')},
  flags, pythonhashseed: 0, order: 'baseline, then only the patch; same incremental build directory', templates,
  limitations: 'Remote compilation only. No graphics, lifecycle, image-equivalence or performance claim. Official installed templates, public runtime and deployment unchanged.'
}, null, 2) + '\n');
JS
printf 'ENGINE_REVIEW: PASS; separate matched templates and hashes saved to %s\n' "$artifact_dir"
