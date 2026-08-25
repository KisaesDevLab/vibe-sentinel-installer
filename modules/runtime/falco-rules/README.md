# Falco rules.d mount

The SENT-C container-runtime pack (SENT-C-001…013) ships from the monorepo
`packages/rules` at build time; per-product allow-list macros (expected
processes, egress lists) are generated from each product's
`vibe-sentinel-manifest.json` — including the CUPS filter-chain allow-list for
Vibe Print, which is generated from the installed filter directory, never
hand-maintained (Decision R16).
