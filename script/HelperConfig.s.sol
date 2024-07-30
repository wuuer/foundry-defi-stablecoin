// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    int256 public constant INITIAL_WETH_PRICE = 2000e8;
    int256 public constant INITIAL_WBTC_PRICE = 3000e8;
    NetworkConfig public activeNetworkConfig;

    constructor() {
        // sepolia online testnet
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        }
        // anvil local testnet
        else {
            activeNetworkConfig = getAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() private view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xb16F35c0Ae2912430DAc15764477E179D9B9EbEa,
            wbtc: 0x6085268aB3e3b414A08762b671DC38243B29621c,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getAnvilEthConfig() private returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();

        MockV3Aggregator mockV3WETHAggreagator = new MockV3Aggregator(DECIMALS, INITIAL_WETH_PRICE);
        MockV3Aggregator mockV3WBTCAggreagator = new MockV3Aggregator(DECIMALS, INITIAL_WBTC_PRICE);

        ERC20Mock weth = new ERC20Mock();

        ERC20Mock wbtc = new ERC20Mock();

        vm.stopBroadcast();

        return NetworkConfig({
            wethUsdPriceFeed: address(mockV3WETHAggreagator),
            wbtcUsdPriceFeed: address(mockV3WBTCAggreagator),
            weth: address(weth),
            wbtc: address(wbtc),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
