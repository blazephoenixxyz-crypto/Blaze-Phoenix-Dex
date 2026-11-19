# Papers

The protocol papers, released with the repository so that a Zenodo record (and its DOI) archives the text beside the code it describes.

| file | what | text licence |
|---|---|---|
| `BlazePhoenix_Whitepaper_v2.2.pdf` | Technical Whitepaper, Version 2.2 — DOI [10.5281/zenodo.22526574](https://doi.org/10.5281/zenodo.22526574) — the aggregator alone: mechanism, mathematics, security model, the verification apparatus measured | CC BY 4.0 |
| `BlazePhoenix_Litepaper_v2.2.pdf` | Litepaper, Version 2.2 — the same protocol for a general reader | CC BY 4.0 |
| `llms.txt` | the whitepaper's machine-readable companion: citation, abstract, measured record, the 24 section openers and both appendices as one-line entries — for indexers, answer engines and AI agents | CC BY 4.0 |
| `llms-full.txt` | the companion followed by the complete paper in one file — one fetch for a machine that wants everything | CC BY 4.0 |
| `whitepaper-v2.2.jsonld` | schema.org ScholarlyArticle for the paper with Appendix A and B as DefinedTermSets | CC BY 4.0 |
| `whitepaper-v2.2.md` | the whitepaper's complete text in Markdown, for citation and ingestion | CC BY 4.0 |

The staking engine is specified in its own paper (https://blazephoenix.xyz/staking-whitepaper.md) and is referenced here, not reproduced.

Every figure printed in the papers is recomputed from a clean checkout by a named command in `docs/assurance/`; the release tag `papers-v2.2` pins the tree the papers describe. The Solidity source remains BUSL-1.1.

Archival record: the whitepaper is registered on Zenodo under the concept DOI [10.5281/zenodo.22526574](https://doi.org/10.5281/zenodo.22526574), which always resolves to the latest record version (currently version 2, [10.5281/zenodo.22529654](https://doi.org/10.5281/zenodo.22529654)). Cite the concept DOI.

Version 2.3 of the whitepaper is archived as a separate record: [10.5281/zenodo.23084091](https://doi.org/10.5281/zenodo.23084091) (concept DOI [10.5281/zenodo.23084090](https://doi.org/10.5281/zenodo.23084090)). Its text is at https://blazephoenix.xyz/whitepaper.md; the record above remains the archive of the Version 2.2 files in this directory.

Version 2.3.1 (2026-11-16) is a new version in that concept: [10.5281/zenodo.24372939](https://doi.org/10.5281/zenodo.24372939), text CC BY-NC-ND 4.0. It corrects three statements of Version 2.3 and changes nothing else: the code licence's Change Date is 2030-06-01, as `LICENSE` states (Version 2.3 printed 2030-07-01); the staking line of the §20 allocation table states the emission design of the staking contract (two independent deployments, each capped at 90,000,000 over 8 years, a linear base plus a bonus that halves every two years; the 180,000,000 total is unchanged); and the text licence. Version 2.3 remains valid at its own DOI and keeps CC BY 4.0.

The research papers, Version 1.0 (2026-11-19), are a separate record: [10.5281/zenodo.24372935](https://doi.org/10.5281/zenodo.24372935), five documents (monoslot encoding, conservation-based solvency, transient callback context, invariant-driven design, technical compendium), text CC BY-NC-ND 4.0.
