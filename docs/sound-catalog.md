# Sound catalog

Unableton ships six procedural instruments and no sampled banks. The hard-coded
download catalog currently contains 42 FreePats banks exposing 45 sampled
instrument presets. Downloading every bank requires 770.66 MiB of archive data
and 2110.92 MiB of installed SF2 data. These are measured file sizes, not the
rounded estimates on the FreePats website.

The catalog retains the five original artifact versions and musical identities.
FM Piano 1 exposes four separately selectable programs in one downloaded bank.
Only explicitly declared General MIDI program numbers are used for new MIDI
program changes. Native percussion key numbers are described in the catalog;
they are not assumed to follow General MIDI percussion mapping.

## Review and exclusions

The explicit audit downloaded all 55 distinct full-quality SF2 candidates linked
from the FreePats instrument pages. It inspected archive contents, computed
archive and SF2 SHA-256 hashes, parsed preset and sample key zones, and rendered
low, middle and high advertised keys in fresh AVAudioUnitSampler graphs. Each
render uses production-style pre-render MIDI scheduling at velocity 100. The
audit ran on macOS 26.5.1 arm64. It measures finite, non-silent output; it does not
establish musical quality or every key/velocity combination.

Thirteen new banks were excluded because the native sampler produced exact
silence at an advertised control key: Glasses of Water, Hang, Tubular Bells,
the five FSBS electric guitar banks, Bagpipe, Kalimba, Timpani, World Percussion,
and Wooden Recorder. The report records exact versions, artifact URLs, hashes,
and failing keys. Their source files may work in other samplers; this audit does
not establish the cause of the native incompatibility.

Accordion has no SF2 download. Overlapping General MIDI collections are excluded;
an obsolete linked percussion-set page returned 404. Duplicate small-quality
variants and alternative SFZ/Hydrogen formats are not catalog candidates.

The existing MuldjordKit is retained for document compatibility, with an explicit
partial-compatibility warning. All 13 distinct mapped native keys were tested.
Only the kick/snare mappings were non-silent; the report identifies silent
project and native pitches. Its original range, IDs, hash and mapping remain
unchanged, and it is not reported as fully validated.

Machine-readable evidence is in `sound-library-audit.json`; attribution and
license links are in the root `THIRD_PARTY_NOTICES.md`.

## Reproducing the audit

Run explicitly from the repository root:

```sh
python3 script/audit_freepats.py
swiftc script/audit_sound_banks.swift -o .cache/catalog-audit/native-audit
.cache/catalog-audit/native-audit
python3 script/freeze_sound_catalog.py
```

These commands can download several GiB including rejected candidates and
extracted audit files. Nothing is installed into the user's managed sound
library. The `.cache/catalog-audit` files are never a production lookup path and
are excluded from Git. The normal app build, test suite and startup do not run
this network audit.

Review changed sources and exclusions before freezing an updated catalog. Never
change the artifact behind an existing instrument ID to a different sound.
