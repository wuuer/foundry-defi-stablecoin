// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentrializedStableCoin} from "../../src/DecentrializedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine private dscEngine;
    DecentrializedStableCoin private dsc;
    address weth;
    address wbtc;
    address[] userWithCollateral;
    MockV3Aggregator wethUsdPriceFeed;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentrializedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        address[] memory tokens = dscEngine.getCollateralTokens();
        weth = tokens[0];
        wbtc = tokens[1];

        wethUsdPriceFeed = MockV3Aggregator(dscEngine.getTokenPriceFeed(weth));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        address collateralTokenAddress = _getCollateralTokenAddressFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        ERC20Mock(collateralTokenAddress).mint(msg.sender, amountCollateral);
        ERC20Mock(collateralTokenAddress).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(collateralTokenAddress, amountCollateral);
        vm.stopPrank();
        userWithCollateral.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        address collateralTokenAddress = _getCollateralTokenAddressFromSeed(collateralSeed);
        uint256 depositedCollateral = dscEngine.getDepositedCollateral(msg.sender);
        if (depositedCollateral == 0) {
            return;
        }
        amountCollateral = bound(amountCollateral, 1, depositedCollateral);
        dscEngine.redeemCollateral(collateralTokenAddress, amountCollateral);
    }

    function mintDSC(uint256 userWithCollateralSeed) public {
        console.log("userWithCollateralSeed: ", userWithCollateralSeed);
        if (userWithCollateral.length == 0) {
            return;
        }
        address user = userWithCollateral[userWithCollateralSeed % userWithCollateral.length];

        vm.startPrank(user);
        (uint256 totalDSCMinted, uint256 totalCallateralValueInUSD) = dscEngine.getAccountInformation();
        int256 maxDSCToMint = (int256(totalCallateralValueInUSD) * int256(dscEngine.getLIQUIDATION_THRESHOLD()))
            / int256(dscEngine.getLIQUIDATIONPRECISION()) - int256(totalDSCMinted);
        console.log("maxDSCToMint:", maxDSCToMint);
        if (maxDSCToMint <= 0) {
            return;
        }
        uint256 amount = 0;
        amount = bound(userWithCollateralSeed, 1, uint256(maxDSCToMint));

        dscEngine.mintDSC(amount);
        vm.stopPrank();
    }

    // break wethValue + wbtcValue >= totalSupply if the price plummet
    // function updatePriceFeed(uint96 newPrice) public {
    //     wethUsdPriceFeed.updateAnswer(int256(uint256(newPrice)));
    // }

    // helper functions
    function _getCollateralTokenAddressFromSeed(uint256 collateralSeed) private view returns (address) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
