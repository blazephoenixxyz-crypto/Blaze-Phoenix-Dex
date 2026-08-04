// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Configurable ERC20 for exercising BlazePhoenixCore's raw-assembly
///         safeTransfer/safeTransferFrom against non-standard token behaviour:
///         no return data (USDT-style), return-false-on-failure instead of
///         reverting, and fee-on-transfer (deflationary) delivery.
contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint16  public feeOnTransferBps;
    bool    public noReturnData;
    bool    public returnFalseOnFail;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function setFeeOnTransferBps(uint16 bps) external { feeOnTransferBps = bps; }
    function setNoReturnData(bool b) external { noReturnData = b; }
    function setReturnFalseOnFail(bool b) external { returnFalseOnFail = b; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        if (noReturnData) { assembly { return(0, 0) } }
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _transfer(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) {
                if (a < amt) {
                    if (returnFalseOnFail) {
                        if (noReturnData) { assembly { return(0, 0) } }
                        return false;
                    }
                    revert("MockERC20: allowance");
                }
                allowance[from][msg.sender] = a - amt;
            }
        }
        return _transfer(from, to, amt);
    }

    function _transfer(address from, address to, uint256 amt) private returns (bool) {
        if (balanceOf[from] < amt) {
            if (returnFalseOnFail) {
                if (noReturnData) { assembly { return(0, 0) } }
                return false;
            }
            revert("MockERC20: balance");
        }
        balanceOf[from] -= amt;
        uint256 delivered = amt;
        if (feeOnTransferBps > 0) {
            uint256 fee = (amt * feeOnTransferBps) / 10_000;
            delivered = amt - fee;
        }
        balanceOf[to] += delivered;
        if (noReturnData) { assembly { return(0, 0) } }
        return true;
    }
}
