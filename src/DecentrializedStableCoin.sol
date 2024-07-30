// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Burnable, ERC20} from "@openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin-contracts/contracts/access/Ownable.sol";

/*
 * @title DecentrializedStableCoin
 * @author
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithemic
 * Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by DSCEngine.This contract is just the ERC20 implementation of our stablecoin system
 *
 */
contract DecentrializedStableCoin is ERC20Burnable, Ownable {
    error DecentrializedStableCoin__MustBeMoreThanZero();
    error DecentrializedStableCoin__BurnAmountExceedsBalance();
    error DecentrializedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentrializedStableCoin", "DSC") Ownable(msg.sender) {}

    function burnFrom(address _from, uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentrializedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentrializedStableCoin__BurnAmountExceedsBalance();
        }

        super._burn(_from, _amount);
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentrializedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentrializedStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, _amount);

        return true;
    }
}
