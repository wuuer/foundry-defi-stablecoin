// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title
 * @author
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * IF a price is stale, the function will revert, and render DSCEngine unusable
 * We want DSCEngine to freeve if prices become stale.
 *
 *
 */
library OracleLib {
    error ORacleLin__StalePrice();

    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 seconds

    function stalePriceCheck(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;

        if (secondsSince > TIMEOUT) {
            revert ORacleLin__StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
