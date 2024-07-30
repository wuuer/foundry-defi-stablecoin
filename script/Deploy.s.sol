// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DecentrializedStableCoin} from "../src/DecentrializedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract Deploy is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DSCEngine, DecentrializedStableCoin, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        DecentrializedStableCoin decentrializedStableCoin = new DecentrializedStableCoin();
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(decentrializedStableCoin));
        // make owner of decentrializedStableCoin is dscEngine
        // Only dscEngine can call function of decentrializedStableCoin
        //console.log(msg.sender);
        decentrializedStableCoin.transferOwnership(address(dscEngine));
        vm.stopBroadcast();

        return (dscEngine, decentrializedStableCoin, helperConfig);
    }
}
