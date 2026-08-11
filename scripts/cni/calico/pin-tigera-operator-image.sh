#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE_IMAGE='quay.io/tigera/operator:v1.42.3'
readonly IMAGE_NAME='quay.io/tigera/operator'
readonly IMAGE_DIGEST='sha256:9ca16aacd5676df68535e08e77529f6c1988ffecbff451e0ff5777e1b126dd91'
readonly KUBECTL='/usr/local/bin/kubectl'

work_dir=$(/usr/bin/mktemp -d)
trap '/usr/bin/rm -rf -- "$work_dir"' EXIT

/usr/bin/tee "$work_dir/rendered.yaml" >/dev/null

source_count=$(/usr/bin/grep -Fc "image: ${SOURCE_IMAGE}" "$work_dir/rendered.yaml" || true)
if [[ "$source_count" -ne 1 ]]; then
  echo "Attesa una occorrenza esatta di ${SOURCE_IMAGE}, trovate ${source_count}." >&2
  exit 1
fi

if /usr/bin/grep -Eq 'image:[[:space:]]+quay\.io/tigera/operator(@|:)(latest|sha256:)' "$work_dir/rendered.yaml"; then
  echo 'Il rendering di ingresso contiene un riferimento operator inatteso.' >&2
  exit 1
fi

{
  echo 'apiVersion: kustomize.config.k8s.io/v1beta1'
  echo 'kind: Kustomization'
  echo 'resources:'
  echo '  - rendered.yaml'
  echo 'images:'
  echo "  - name: ${IMAGE_NAME}"
  echo "    newName: ${IMAGE_NAME}"
  echo "    digest: ${IMAGE_DIGEST}"
} > "$work_dir/kustomization.yaml"

"$KUBECTL" kustomize "$work_dir" > "$work_dir/pinned.yaml"

pinned_count=$(/usr/bin/grep -Fc "image: ${IMAGE_NAME}@${IMAGE_DIGEST}" "$work_dir/pinned.yaml" || true)
if [[ "$pinned_count" -ne 1 ]]; then
  echo "Il post-rendering non ha prodotto il riferimento operator immutabile atteso." >&2
  exit 1
fi

if /usr/bin/grep -Fq "image: ${SOURCE_IMAGE}" "$work_dir/pinned.yaml"; then
  echo 'Il riferimento operator con tag è rimasto nel rendering finale.' >&2
  exit 1
fi

/usr/bin/sed -n '1,$p' "$work_dir/pinned.yaml"
