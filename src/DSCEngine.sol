// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {ERC20Burnable, ERC20} from "@openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin-contracts/contracts/access/Ownable.sol";
import {DecentrializedStableCoin} from "./DecentrializedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author
 *
 * The system is designed to be as minimal as possible,and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmiacally Stable
 *
 * It is similar to DAI IF DAI had no goverance,no fees,and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point,should the value of
 * all collateral <= the $ backed the value of all the DSC.
 *
 * @notice This contract is the core of the DSC system.It hadles all the logic for mining and redeeming DSC,as well as depositing & withrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /* errors */
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMismatched();
    error DSCEngine__TokenDisallowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__CollateralOver(uint256 totalCallateralValueInUSD, uint256 totalCollateralToRedeem);

    /* types */

    using OracleLib for AggregatorV3Interface;

    /* state Variables */
    uint256 public constant ADDITIONAL_PRICE_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50%
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    address[] private s_collateralTokens;
    mapping(address user => uint256 amountDSCMinted) private s_userDSCMinted;

    DecentrializedStableCoin private immutable i_decentrialiedStableCoin;
    mapping(address token => address priceFeedAddress) private i_tokenPriceFeeds;

    /* events */

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 amount);
    event CollateralLiquidationRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /* modifies */

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenDisallowed();
        }
        _;
    }

    /* functions */

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMismatched();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
            i_tokenPriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }

        i_decentrialiedStableCoin = DecentrializedStableCoin(dscAddress);
    }

    /**
     *
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountColleteral the amount of collateral to deposit
     * @param amountDSCToMint the amount of collateral to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountColleteral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountColleteral);
        mintDSC(amountDSCToMint);
    }

    /**
     *
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This will redeem your collateral and burn your DSC
     * @param tokenCollateralAddress the address of the token to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDSCToBurn the amount of DSC to burn
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
    {
        burnDSC(amountDSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice 1. health factor must be over 1 AFTER Collateral pulled
     * @param tokenCollateralAddress token
     * @param amountCollateral amount to collate
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDSCToMint the amount of collateral to mint
     * @notice they must have more callaternal value than the minimum thresold
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_userDSCMinted[msg.sender] += amountDSCToMint;
        // _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_decentrialiedStableCoin.mint(msg.sender, amountDSCToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }

        // if they minted too much ($150 DSC,$100 ETh)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_userDSCMinted[msg.sender] -= amount;

        bool success = i_decentrialiedStableCoin.transferFrom(msg.sender, address(this), amount);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        //i_decentrialiedStableCoin.burnFrom(msg.sender, amount);

        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would hit...
    }

    /**
     * If someone is almost undercollateralled , we will pay you to liquidate them !
     * @param collateralTokenAddress The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor . Their _healthFactor should be
     * below MIN_HEALTh_FACTOR
     * @param debtToCover amount of DSC you want to burn to improve the user health factor
     * @notice You can't partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateraled
     * in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralled,then we wouldn't
     * be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     * Follows: CEI
     */
    function liquidate(address collateralTokenAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR * PRECISION) {
            revert DSCEngine__HealthFactorOK();
        }

        // how much should you cover
        // $? usd of DSC = ??? WETH

        uint256 tokenAmountFromDebtCovered = getTokenAnmountFromUSD(collateralTokenAddress, debtToCover);

        // And give them a 10% bouns
        uint256 bonusCallateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCallateral;

        uint256 totalCallateralAmount = s_collateralDeposited[user][collateralTokenAddress];

        // console.log(totalCollateralToRedeem);
        // console.log(totalCallateralAmount);

        if (totalCollateralToRedeem > totalCallateralAmount) {
            revert DSCEngine__CollateralOver(totalCallateralAmount, totalCollateralToRedeem);
        }

        _redeemLiquidationCollateral(collateralTokenAddress, totalCollateralToRedeem, user, msg.sender);
        _burnLiquidationDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getUserHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    // private & internal functions

    function _redeemLiquidationCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralLiquidationRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice low-level function , do not call unless the function calling it is checking for health factors being broken
     *
     */
    function _burnLiquidationDSC(uint256 amountDSCToBurn, address onBehalOf, address dscFrom) private {
        s_userDSCMinted[onBehalOf] -= amountDSCToBurn;
        s_userDSCMinted[dscFrom] -= amountDSCToBurn;

        bool success = i_decentrialiedStableCoin.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_decentrialiedStableCoin.burnFrom(onBehalOf, amountDSCToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 totalCallateralValueInUSD)
    {
        totalDSCMinted = s_userDSCMinted[user];
        totalCallateralValueInUSD = getAccountCollateralValueInUSD(user);
    }
    /**
     * Returns how close to liquidation a user is
     * if a user goes below 1,then they can get liquidated
     * @param user minting user
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 totalCallateralValueInUSD) = _getAccountInformation(user);

        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustForThreshold =
            (totalCallateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        // 1:1
        if (userHealthFactor < MIN_HEALTH_FACTOR * PRECISION) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    // public & external view functions

    function getAccountCollateralValueInUSD(address user) public view returns (uint256 totalCallateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address tokenAddress = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][tokenAddress];
            if (amount > 0) {
                totalCallateralValueInUSD += getUsdValue(tokenAddress, amount);
            }
        }
    }

    function getUsdValue(address tokenAddress, uint256 amount)
        public
        view
        isAllowedToken(tokenAddress)
        returns (uint256)
    {
        // It will returns number with 8 decimals
        (, int256 answer,,,) = AggregatorV3Interface(i_tokenPriceFeeds[tokenAddress]).stalePriceCheck();

        // convert to Wei then convert back to original
        return (uint256(answer) * ADDITIONAL_PRICE_PRECISION * amount) / PRECISION;
    }

    function getTokenAnmountFromUSD(address tokenAddress, uint256 usdAmountInWei) public view returns (uint256) {
        // It will returns number with 8 decimals
        (, int256 answer,,,) = AggregatorV3Interface(i_tokenPriceFeeds[tokenAddress]).stalePriceCheck();
        // 2000$ -> 1weth
        // 5.45$ -> 5.45$ / 2000$ * 1 weth = 0.00275 weth
        // enlarge the deimals part in case
        return (usdAmountInWei * PRECISION) / (uint256(answer) * ADDITIONAL_PRICE_PRECISION);
    }

    function getAccountInformation()
        external
        view
        returns (uint256 totalDSCMinted, uint256 totalCallateralValueInUSD)
    {
        return _getAccountInformation(msg.sender);
    }

    function getDepositedCollateral(address tokenCollateralAddress) external view returns (uint256) {
        return s_collateralDeposited[msg.sender][tokenCollateralAddress];
    }

    function getLIQUIDATIONPRECISION() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLIQUIDATIONBONUS() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getLIQUIDATION_THRESHOLD() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
