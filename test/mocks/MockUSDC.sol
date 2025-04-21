// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20, ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockUSDC is ERC20Permit {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20Permit(name) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
