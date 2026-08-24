// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice Os 41 tokens mais liquidos da Optimism, colhidos do GeckoTerminal
///         a 2026-08-21 e ordenados por liquidez USD acumulada nas pools onde
///         aparecem. Gerado por script — nao editar a mao.
library Top100OptimismTokens {
    struct Entry { string symbol; address token; }

    function all() internal pure returns (Entry[41] memory e) {
        e[0] = Entry("USDC", 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);  // $25.47M
        e[1] = Entry("USDT", 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);  // $16.54M
        e[2] = Entry("WETH", 0x4200000000000000000000000000000000000006);  // $15.93M
        e[3] = Entry("USD0", 0x01bFF41798a0BcF287b996046Ca68b395DbC1071);  // $3.84M
        e[4] = Entry("alETH", 0x3E29D3A9316dAB217754d13b28646B76607c5f04);  // $3.16M
        e[5] = Entry("WBTC", 0x68f180fcCe6836688e9084f035309E29Bf0A2095);  // $2.34M
        e[6] = Entry("OP", 0x4200000000000000000000000000000000000042);  // $1.87M
        e[7] = Entry("VELO", 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);  // $1.82M
        e[8] = Entry("alUSD", 0xCB8FA9a76b8e203D8C3797bF438d8FB81Ea3326A);  // $1.66M
        e[9] = Entry("USDC", 0x7F5c764cBc14f9669B88837ca1490cCa17c31607);  // $1.17M
        e[10] = Entry("msETH", 0x1610e3c85dd44Af31eD7f33a63642012Dca0C5A5);  // $1.12M
        e[11] = Entry("msUSD", 0x9dAbAE7274D28A45F0B65Bf8ED201A5731492ca0);  // $0.88M
        e[12] = Entry("crvUSD", 0xC52D7F23a2e460248Db6eE192Cb23dD12bDDCbf6);  // $0.84M
        e[13] = Entry("wstETH", 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb);  // $0.77M
        e[14] = Entry("DAI", 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);  // $0.71M
        e[15] = Entry("rETH", 0x9Bcef72be871e61ED4fBbc7630889beE758eb81D);  // $0.71M
        e[16] = Entry("TAROT", 0x1F514A61bcde34F94Bc39731235690ab9da737F7);  // $0.30M
        e[17] = Entry("EURC", 0xDCB612005417Dc906fF72c87DF732e5a90D49e11);  // $0.18M
        e[18] = Entry("LINK", 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6);  // $0.16M
        e[19] = Entry("OVER", 0xedF38688b27036816A50185cAA430D5479e1C63e);  // $0.16M
        e[20] = Entry("mooBIFI", 0xc55E93C62874D8100dBd2DfE307EDc1036ad5434);  // $0.16M
        e[21] = Entry("AAVE", 0x76FB31fb4af56892A25e32cFC43De717950c9278);  // $0.14M
        e[22] = Entry("SNX", 0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4);  // $0.14M
        e[23] = Entry("HAI", 0x10398AbC267496E49106B07dd6BE13364D10dC71);  // $0.13M
        e[24] = Entry("OpenX", 0xc3864f98f2a61A7cAeb95b039D031b4E2f55e0e9);  // $0.10M
        e[25] = Entry("WLD", 0xdC6fF44d5d932Cbd77B52E5612Ba0529DC6226F1);  // $0.10M
        e[26] = Entry("FRAX", 0x2E3D870790dC77A83DD1d18184Acc7439A53f475);  // $0.10M
        e[27] = Entry("ZRO", 0x6985884C4392D348587B19cb9eAAf157F13271cd);  // $0.07M
        e[28] = Entry("UNI", 0x6fd9d7AD17242c41f7131d257212c54A0e816691);  // $0.06M
        e[29] = Entry("frxETH", 0x6806411765Af15Bddd26f8f544A34cC40cb9838B);  // $0.06M
        e[30] = Entry("VELO", 0x3c8B650257cFb5f272f799F5e2b4e65093a11a05);  // $0.05M
        e[31] = Entry("LUSD", 0xc40F949F8a4e094D1b49a23ea9241D289B7b2819);  // $0.04M
        e[32] = Entry("STG", 0x296F55F8Fb28E498B858d0BcDA06D955B2Cb3f97);  // $0.03M
        e[33] = Entry("BOLD", 0x03569CC076654F82679C4BA2124D64774781B01D);  // $0.03M
        e[34] = Entry("ITP", 0x0a7B751FcDBBAA8BB988B9217ad5Fb5cfe7bf7A0);  // $0.03M
        e[35] = Entry("TQian", 0x2042a675F3caeDf00939EF55ad40753b8F2B973C);  // $0.03M
        e[36] = Entry("ERN", 0xc5b001DC33727F8F26880B184090D3E252470D45);  // $0.02M
        e[37] = Entry("CRV", 0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53);  // $0.01M
        e[38] = Entry("THALES", 0x217D47011b23BB961eB6D93cA9945B7501a5BB11);  // $0.00M
        e[39] = Entry("agEUR", 0x9485aca5bbBE1667AD97c7fE7C4531a624C8b1ED);  // $0.00M
        e[40] = Entry("USDM", 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C);  // $0.00M
    }
}