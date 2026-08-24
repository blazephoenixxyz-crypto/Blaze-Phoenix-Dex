// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice Os 59 tokens mais liquidos da Arbitrum, colhidos do GeckoTerminal
///         a 2026-08-21 e ordenados por liquidez USD acumulada nas pools onde
///         aparecem. Gerado por script — nao editar a mao.
library Top100ArbitrumTokens {
    struct Entry { string symbol; address token; }

    function all() internal pure returns (Entry[59] memory e) {
        e[0] = Entry("USDC", 0xaf88d065e77c8cC2239327C5EDb3A432268e5831);  // $657.89M
        e[1] = Entry("USDT", 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);  // $597.73M
        e[2] = Entry("WETH", 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);  // $110.62M
        e[3] = Entry("WBTC", 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);  // $100.84M
        e[4] = Entry("cbBTC", 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);  // $34.32M
        e[5] = Entry("ARB", 0x912CE59144191C1204E64559FE8253a0e49E6548);  // $6.25M
        e[6] = Entry("Dory", 0x33b49f2264e85bB124d2730DC180182717D436Ae);  // $5.28M
        e[7] = Entry("PENDLE", 0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8);  // $4.66M
        e[8] = Entry("USDC", 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);  // $4.04M
        e[9] = Entry("RAIN", 0x25118290e6A5f4139381D072181157035864099d);  // $2.43M
        e[10] = Entry("LINK", 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4);  // $2.39M
        e[11] = Entry("HEGIC", 0x431402e8b9dE9aa016C743880e04E517074D8cEC);  // $2.23M
        e[12] = Entry("VSN", 0x6fBBbD8bFB1cd3986B1D05e7861a0f62F87DB74b);  // $1.35M
        e[13] = Entry("MOR", 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86);  // $1.26M
        e[14] = Entry("GMX", 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a);  // $1.20M
        e[15] = Entry("CHIP", 0x0C1c1C109FE34733fca54b82d7B46B75CFb71F6e);  // $1.10M
        e[16] = Entry("wstETH", 0x5979D7b546E38E414F7E9822514be443A4800529);  // $0.97M
        e[17] = Entry("NOX", 0xb23bB8c2C6Cb9169eeaC8f2Bd42fcf333A1a8C55);  // $0.92M
        e[18] = Entry("AAVE", 0xba5DdD1f9d7F570dc94a51479a000E3BCE967196);  // $0.71M
        e[19] = Entry("ESP", 0x3b8db18e69d6686Ad9371A423aFe3Dd1065C94f1);  // $0.55M
        e[20] = Entry("CRV", 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978);  // $0.50M
        e[21] = Entry("UNI", 0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0);  // $0.49M
        e[22] = Entry("AIDOGE", 0x09E18590E8f76b6Cf471b3cd75fE1A1a9D2B2c2b);  // $0.49M
        e[23] = Entry("LAVA", 0x11e969e9B3f89cB16D686a03Cd8508C9fC0361AF);  // $0.48M
        e[24] = Entry("SQD", 0x1337420dED5ADb9980CFc35f8f2B054ea86f8aB1);  // $0.40M
        e[25] = Entry("DAI", 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);  // $0.35M
        e[26] = Entry("ETHFI", 0x7189fb5B6504bbfF6a852B13B7B82a3c118fDc27);  // $0.33M
        e[27] = Entry("GNS", 0x18c11FD286C5EC11c3b683Caa813B77f5163A122);  // $0.32M
        e[28] = Entry("EVA", 0x45D9831d8751B2325f3DBf48db748723726e1C8c);  // $0.31M
        e[29] = Entry("crvUSD", 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5);  // $0.28M
        e[30] = Entry("AMXYZ", 0x945419B49D29864AC3D2800c44a41F346Cac93e1);  // $0.28M
        e[31] = Entry("LPT", 0x289ba1701C2F088cf0faf8B3705246331cB8A839);  // $0.22M
        e[32] = Entry("APEX", 0x61A1ff55C5216b636a294A07D77C6F4Df10d3B56);  // $0.18M
        e[33] = Entry("waArbUSDCn", 0x7F6501d3B98eE91f9b9535E4b0ac710Fb0f9e0bc);  // $0.18M
        e[34] = Entry("waArbUSDT", 0xa6D12574eFB239FC1D2099732bd8b5dC6306897F);  // $0.18M
        e[35] = Entry("MAGIC", 0x539bdE0d7Dbd336b79148AA742883198BBF60342);  // $0.18M
        e[36] = Entry("ZRO", 0x6985884C4392D348587B19cb9eAAf157F13271cd);  // $0.17M
        e[37] = Entry("NST", 0x88a269Df8fe7F53E590c561954C52FCCC8EC0cFB);  // $0.17M
        e[38] = Entry("ORDER", 0x4E200fE2f3eFb977d5fd9c430A41531FB04d97B8);  // $0.16M
        e[39] = Entry("WINR", 0xD77B108d4f6cefaa0Cae9506A934e825BEccA46E);  // $0.15M
        e[40] = Entry("URANO", 0x5AF01e4d2bEFf2b01A8F3992e875EDd8d67469D2);  // $0.12M
        e[41] = Entry("tBTC", 0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40);  // $0.11M
        e[42] = Entry("ENI", 0xfC04Fd1E034319a2c1073124d69C7eC2E7b644a9);  // $0.10M
        e[43] = Entry("ANT", 0xa78d8321B20c4Ef90eCd72f2588AA985A4BDb684);  // $0.10M
        e[44] = Entry("Cake", 0x1b896893dfc86bb67Cf57767298b9073D2c1bA2c);  // $0.07M
        e[45] = Entry("SOL", 0x2bcC6D6CdBbDC0a4071e48bb3B969b06B3330c07);  // $0.06M
        e[46] = Entry("ODYS", 0x018D6a98555686bE1CA5b6896ef6c42cf67E2BD1);  // $0.05M
        e[47] = Entry("GRT", 0x9623063377AD1B27544C965cCd7342f7EA7e88C7);  // $0.05M
        e[48] = Entry("LDO", 0x13Ad51ed4F1B7e9Dc168d8a00cB3f4dDD85EfA60);  // $0.05M
        e[49] = Entry("USDai", 0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF);  // $0.05M
        e[50] = Entry("ATH", 0xc87B37a581ec3257B734886d9d3a581F5A9d056c);  // $0.04M
        e[51] = Entry("ETH", 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);  // $0.03M
        e[52] = Entry("MILES", 0x6beadFCC25F6BC71C158a4Bff85bf2F1746D2ca7);  // $0.02M
        e[53] = Entry("KISUNE", 0x5144443DAbdAA076a215364F7D55f261Dcae66Cb);  // $0.01M
        e[54] = Entry("STG", 0x6694340fc020c5E6B96567843da2df01b2CE1eb6);  // $0.01M
        e[55] = Entry("GenZ", 0x719A06aCbe535B85CCb8c9a2b59cab9f8b9BCe57);  // $0.01M
        e[56] = Entry("Up", 0x1009c5c11CDD44bfFeAC3C70dB7EB143df2fAAd1);  // $0.01M
        e[57] = Entry("USD", 0xe80772Eaf6e2E18B651F160Bc9158b2A5caFCA65);  // $0.00M
        e[58] = Entry("wXFO", 0x25CF13Fe02af9181cb5361bAc4610E5C2e8B2519);  // $0.00M
    }
}