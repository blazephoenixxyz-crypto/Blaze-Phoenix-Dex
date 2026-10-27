// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The window of a gas-measured fee read, in runtime code. A read measured as
/// `g0 := gas(); ok := staticcall(budget, ...); spent := sub(g0, gas())` counts, besides what the
/// call costs (the account access and all the callee consumes), the static gas of the ops the
/// compiler places after the first GAS and up to the second (that GAS included, the call
/// excluded): the window. Two compiled instances of the same read differ by their windows only,
/// and the compiler chooses them (stack layout), not the source.
/// `scan` finds every STATICCALL with a PUSH of `budget` among the 16 ops before it, takes the
/// nearest GAS before the call and the first GAS after it, and prices the ops in between. A
/// budget call without the two GAS reads, or an op it does not price, reverts: a window it cannot
/// price is not bounded.
library FeeReadWindow {
    function scan(bytes memory code, uint256 budget) internal pure returns (uint256 sites, uint256 widest) {
        uint256 len = code.length;
        uint256[] memory opAt = new uint256[](len);
        uint256 n;
        for (uint256 i; i < len;) {
            opAt[n++] = i;
            uint8 op = uint8(code[i]);
            i += op >= 0x60 && op <= 0x7f ? op - 0x5e : 1;
        }
        for (uint256 k = 1; k < n; ++k) {
            if (uint8(code[opAt[k]]) != 0xfa) continue; // STATICCALL
            uint256 from = k > 16 ? k - 16 : 0;
            bool isBudget;
            for (uint256 j = from; j < k; ++j) if (_pushes(code, opAt[j], budget)) isBudget = true;
            if (!isBudget) continue;
            uint256 j0 = type(uint256).max;
            for (uint256 j = from; j < k; ++j) if (uint8(code[opAt[j]]) == 0x5a) j0 = j;
            require(j0 != type(uint256).max, "FeeReadWindow: no GAS read before the call");
            uint256 j1 = type(uint256).max;
            for (uint256 j = k + 1; j < n && j <= k + 8; ++j) {
                if (uint8(code[opAt[j]]) == 0x5a) { j1 = j; break; }
            }
            require(j1 != type(uint256).max, "FeeReadWindow: no GAS read after the call");
            uint256 w;
            for (uint256 j = j0 + 1; j <= j1; ++j) if (j != k) w += _cost(uint8(code[opAt[j]]));
            ++sites;
            if (w > widest) widest = w;
        }
    }

    function _pushes(bytes memory code, uint256 pos, uint256 v) private pure returns (bool) {
        uint8 op = uint8(code[pos]);
        if (op < 0x60 || op > 0x7f) return false;
        uint256 width = op - 0x5f;
        if (pos + width >= code.length) return false;
        uint256 x;
        for (uint256 t = 1; t <= width; ++t) x = (x << 8) | uint8(code[pos + t]);
        return x == v;
    }

    function _cost(uint8 op) private pure returns (uint256) {
        if (op == 0x5f || op == 0x50 || op == 0x5a) return 2; // PUSH0, POP, GAS
        if (op >= 0x60 && op <= 0x9f) return 3; // PUSH1-32, DUP1-16, SWAP1-16
        revert("FeeReadWindow: an op in the window is not priced");
    }
}
