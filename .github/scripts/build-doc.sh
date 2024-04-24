#!/bin/sh

set -e

cd /tmp/liquidsoap-full/liquidsoap
eval "$(opam config env)"
OCAMLPATH="$(cat ../.ocamlpath)"
export OCAMLPATH

opam install -y odoc
dune build @doc
dune build --profile release ./src/js/interactive_js.bc.js
