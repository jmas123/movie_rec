#!/bin/zsh
#
# Offline evaluation of the recommender — see docs/RECOMMENDER-EVALUATION.md.
#
#   scripts/eval/run.sh [work-dir]
#
# Fetches the fixture (once, then cached), compiles the harness against the app
# sources, evaluates on three held-out splits, and draws the figures.
#
# Dev tooling: it runs on the Mac, not in the app, so matplotlib here does not
# touch the app's no-dependencies rule.

set -e

ROOT=${0:a:h:h:h}
WORK=${1:-$ROOT/.eval}
mkdir -p $WORK

cd $ROOT

# 1. Fixture: MovieLens ratings + TMDB metadata.
if [[ ! -f $WORK/users.json ]]; then
  if [[ ! -d $WORK/ml-latest-small ]]; then
    curl -sL -o $WORK/ml.zip https://files.grouplens.org/datasets/movielens/ml-latest-small.zip
    unzip -oq $WORK/ml.zip -d $WORK
  fi
  python3 scripts/eval/fetch_movielens_fixture.py --data $WORK/ml-latest-small --out $WORK
fi

# 2. Harness, compiled against the app's own engines.
#
# Copied to a snapshot first: concurrent edits to the working tree make swiftc
# fail with "input file was modified during the build", and DiagnosticsReporter
# is MetricKit, which does not exist on macOS.
SNAP=$WORK/app-src
rm -rf $SNAP && mkdir -p $SNAP
cp Binged/Binged/Models/*.swift Binged/Binged/Services/*.swift \
   Binged/Binged/Services/Supabase/*.swift Binged/Binged/ViewModels/*.swift $SNAP/
rm -f $SNAP/DiagnosticsReporter.swift
# Top-level code is only legal in a file called main.swift, hence the copy.
cp scripts/eval/recommender_eval.swift $WORK/main.swift
swiftc -swift-version 5 -O -o $WORK/recommender_eval $WORK/main.swift $SNAP/*.swift

# 3. Three independent held-out splits.
for seed in 7 23 91; do
  EVAL_DIR=$WORK SPLIT_SEED=$seed OUT_NAME=confirm$seed.json $WORK/recommender_eval
done

# 4. Figures and the summary table.
if [[ ! -d $WORK/venv ]]; then
  python3 -m venv $WORK/venv
  $WORK/venv/bin/pip install --quiet matplotlib numpy
fi
EVAL_DIR=$WORK $WORK/venv/bin/python scripts/eval/report.py

echo
echo "figures: $WORK/figures"
