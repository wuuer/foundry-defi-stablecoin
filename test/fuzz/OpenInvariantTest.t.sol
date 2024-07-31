// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// // Invariants:
// // 1. The total supply of DSC should be less than the total value of collateral
// // 2. Getter view functions should never revert

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {Deploy} from "../../script/Deploy.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentrializedStableCoin} from "../../src/DecentrializedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

// contract OpenInvariantTest is StdInvariant, Test {
//     DSCEngine private dscEngine;
//     DecentrializedStableCoin private dsc;
//     HelperConfig private config;
//     address private weth;
//     address private wbtc;

//     function setUp() external {
//         Deploy deploy = new Deploy();
//         (dscEngine, dsc, config) = deploy.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

//         console.log("wethValue,", wethValue);
//         console.log("wbtcValue,", wbtcValue);
//         console.log("totalSupply,", totalSupply);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
