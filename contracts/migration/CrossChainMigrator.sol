// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "../interfaces/IERC20.sol";
import "../interfaces/IOwnable.sol";
import "../types/Ownable.sol";
import "../libraries/SafeERC20.sol";

contract CrossChainMigrator is Ownable {
    using SafeERC20 for IERC20;

    IERC20 internal immutable wsAXDS; // v1 token
    IERC20 internal immutable gAXDS; // v2 token

    constructor(address _wsAXDS, address _gAXDS) {
        require(_wsAXDS != address(0), "Zero address: wsAXDS");
        wsAXDS = IERC20(_wsAXDS);
        require(_gAXDS != address(0), "Zero address: gAXDS");
        gAXDS = IERC20(_gAXDS);
    }

    // migrate wsAXDS to gAXDS - 1:1 like kind
    function migrate(uint256 amount) external {
        wsAXDS.safeTransferFrom(msg.sender, address(this), amount);
        gAXDS.safeTransfer(msg.sender, amount);
    }

    // withdraw wsAXDS so it can be bridged on ETH and returned as more gAXDS
    function replenish() external onlyOwner {
        wsAXDS.safeTransfer(msg.sender, wsAXDS.balanceOf(address(this)));
    }

    // withdraw migrated wsAXDS and unmigrated gAXDS
    function clear() external onlyOwner {
        wsAXDS.safeTransfer(msg.sender, wsAXDS.balanceOf(address(this)));
        gAXDS.safeTransfer(msg.sender, gAXDS.balanceOf(address(this)));
    }
}
