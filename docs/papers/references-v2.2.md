# References — whitepaper-v2.2.md

Every entry below was verified on 2026-09-06 from this device. Web sources: `curl -s -o /dev/null -w '%{http_code}' -L --max-time 25 -A 'Mozilla/5.0' <url>` returned the code shown. DOIs: `curl -s -L -H 'Accept: application/vnd.citationstyles.csl+json' https://doi.org/<doi>` returned Crossref metadata whose title, container and year are quoted in the verification line (the publisher landing pages of ACM and IOS Press answer 403 to a bare request; the DOI resolves regardless). Numbering matches the References section of the paper. Entries the 3.0 base carried but this edition does not cite (Angeris et al. 2019; Angeris & Chitra 2020; Egorov 2021 CryptoSwap; Robinson & Konstantopoulos 2020; samczsun 2020) are omitted rather than listed unread; the two entries of `sources/refs-v1.bib` marked "not yet opened" that this edition keeps (Cousot & Cousot 1977, Chen et al. 1998) are now verified below; Jacob 1989 and the 2025 medians preprint are not cited and are omitted.

| # | Entry | Verified | Cited in |
|---|---|---|---|
| 1 | G. Angeris, A. Evans, T. Chitra, S. Boyd. *Optimal Routing for Constant Function Market Makers.* arXiv:2204.05238, 2022 (also ACM EC '22). https://arxiv.org/abs/2204.05238 | curl → 200 | §10.4, §23 |
| 2 | T. Diamandis, M. Resnick, T. Chitra, G. Angeris. *An Efficient Algorithm for Optimal Routing Through Constant Function Market Makers.* arXiv:2302.04938, 2023 (Financial Cryptography 2023). https://arxiv.org/abs/2302.04938 | curl → 200 | §23 |
| 3 | H. Adams, N. Zinsmeister, D. Robinson. *Uniswap v2 Core.* 2020. https://uniswap.org/whitepaper.pdf | curl → 200 | §4.2, §23 |
| 4 | H. Adams, N. Zinsmeister, M. Salem, R. Keefer, D. Robinson. *Uniswap v3 Core.* 2021. https://uniswap.org/whitepaper-v3.pdf | curl → 200 | §4.2, §15.6, §23 |
| 5 | Uniswap Labs (H. Adams et al.). *Uniswap v4 Core.* 2024. https://uniswap.org/whitepaper-v4.pdf | curl → 200 | §5, §14.2, §23 |
| 6 | M. Egorov. *StableSwap — Efficient Mechanism for Stablecoin Liquidity.* 2019. https://curve.fi/files/stableswap-paper.pdf | curl → 200 | §4.1, §23 |
| 7 | P. Daian, S. Goldfeder, T. Kell, Y. Li, X. Zhao, I. Bentov, L. Breidenbach, A. Juels. *Flash Boys 2.0: Frontrunning in Decentralized Exchanges, Miner Extractable Value, and Consensus Instability.* IEEE Symposium on Security and Privacy, 2020. DOI 10.1109/SP40000.2020.00040; arXiv:1904.05234 | Crossref → "Flash Boys 2.0: Frontrunning in Decentralized Exchanges, Miner Extract…", 2020 IEEE S&P, 2020; arXiv curl → 200 | §14.3, §23 |
| 8 | L. Zhou, K. Qin, C. F. Torres, D. V. Le, A. Gervais. *High-Frequency Trading on Decentralized On-Chain Exchanges.* IEEE Symposium on Security and Privacy, 2021. DOI 10.1109/SP40001.2021.00027; arXiv:2009.14021 | Crossref → "High-Frequency Trading on Decentralized On-Chain Exchanges", 2021 IEEE S&P, 2021; arXiv curl → 200 | §14.3, §23 |
| 9 | P. Cousot, R. Cousot. *Abstract Interpretation: A Unified Lattice Model for Static Analysis of Programs by Construction or Approximation of Fixpoints.* POPL, 1977. DOI 10.1145/512950.512973 | Crossref → "Abstract interpretation", Proceedings of the 4th ACM SIGACT-SIGPLAN symposium, 1977 | §23 |
| 10 | M. R. Clarkson, F. B. Schneider. *Hyperproperties.* Journal of Computer Security 18(6), 1157–1210, 2010. DOI 10.3233/JCS-2009-0393 | Crossref → "Hyperproperties", Journal of Computer Security, 2010 | §21, §23 |
| 11 | T. Y. Chen, S. C. Cheung, S. M. Yiu. *Metamorphic Testing: A New Approach for Generating Next Test Cases.* Technical Report HKUST-CS98-01, 1998; arXiv:2002.12543 (2020). https://arxiv.org/abs/2002.12543 | curl → 200 | §15.7, §23 |
| 12 | R. A. DeMillo, R. J. Lipton, F. G. Sayward. *Hints on Test Data Selection: Help for the Practicing Programmer.* IEEE Computer 11(4), 1978. DOI 10.1109/C-M.1978.218136 | Crossref → "Hints on Test Data Selection: Help for the Practicing Programmer", Computer, 1978 | §15.2, §23 |
| 13 | A. Avizienis. *The N-Version Approach to Fault-Tolerant Software.* IEEE Transactions on Software Engineering SE-11(12), 1985. DOI 10.1109/TSE.1985.231893 | Crossref → "The N-Version Approach to Fault-Tolerant Software", IEEE TSE, 1985 | §15.8, §23 |
| 14 | D. R. Kuhn, R. N. Kacker, Y. Lei. *Practical Combinatorial Testing.* NIST Special Publication 800-142, 2010. DOI 10.6028/NIST.SP.800-142 | Crossref → "Practical combinatorial testing", 2010; curl → 200 | §15.4, §23 |
| 15 | B. Littlewood, L. Strigini. *Validation of Ultrahigh Dependability for Software-Based Systems.* Communications of the ACM 36(11), 1993. DOI 10.1145/163359.163373 | Crossref → "Validation of ultrahigh dependability for software-based systems", Communications of the ACM, 1993 | §15.11, §23 |
| 16 | A. Akhunov, M. H. Swende. *EIP-1153: Transient Storage Opcodes.* https://eips.ethereum.org/EIPS/eip-1153 | curl → 200 | §11.4, §13.2, §23 |
| 17 | V. Buterin. *EIP-170: Contract Code Size Limit.* https://eips.ethereum.org/EIPS/eip-170 | curl → 200 | §16.3, §23 |
| 18 | V. Buterin. *EIP-1014: Skinny CREATE2.* https://eips.ethereum.org/EIPS/eip-1014 | curl → 200 | §7, §23 |
| 19 | M. Lundfall et al. *EIP-2612: Permit Extension for EIP-20 Signed Approvals.* https://eips.ethereum.org/EIPS/eip-2612 · Uniswap Labs. *Permit2.* https://github.com/Uniswap/permit2 | curl → 200; curl → 200 | §11.1, §23 |
| 20 | V. Buterin, S. Feist et al. *EIP-7702: Set Code for EOAs.* https://eips.ethereum.org/EIPS/eip-7702 | curl → 200 | §11.1, §23 |
| 21 | *ERC-7201: Namespaced Storage Layout.* https://eips.ethereum.org/EIPS/eip-7201 | curl → 200 | §16.1, §23 |
| 22 | MariaDB Corporation Ab. *Business Source License 1.1.* https://mariadb.com/bsl11/ | curl → 200 | cover |
| 23 | Mitra. *BlazePhoenix Staking Engine — Design Specification, Version 1.0.* https://blazephoenix.xyz/staking-whitepaper.md | curl → 200 | §18, §20 |
| 24 | Fable & Mitra. *BlazePhoenix-Dex: an on-chain DEX aggregator with measured routing.* Repository, `main` 8949a9d, 2026-09-05. https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex | curl → 200 | throughout; Appendix C |

Raw verification log: scratchpad `refcheck.txt` (28 URLs; 200 for all direct sources; 403 on the ACM and IOS Press landing pages and 202 on IEEE Xplore, each then confirmed through Crossref as above).
