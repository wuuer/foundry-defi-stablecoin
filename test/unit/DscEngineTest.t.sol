// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentrializedStableCoin} from "../../src/DecentrializedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DscEngineTest is Test {
    DSCEngine private dscEngine;
    DecentrializedStableCoin private dsc;
    address private weth;
    int256 private INITIAL_WETH_PRICE;
    uint256 private ADDITIONAL_PRICE_PRECISION;
    uint256 private PRECISION;

    address private wethUsdPriceFeed;
    address private user = makeAddr("user");
    uint256 private LIQUIDATION_BONUS;
    uint256 private LIQUIDATION_PRECISION;
    uint256 private constant AMOUNT_COLLATERAL = 10 ether;
    uint256 private constant AMOUNT_DSCMINTED = 6 ether; // equals to 6 USD
    uint256 private constant STARING_ERC20_BALANCE = 100 ether;

    function setUp() public {
        Deploy deploy = new Deploy();
        (DSCEngine _dscEngine, DecentrializedStableCoin _dsc, HelperConfig config) = deploy.run();
        dscEngine = _dscEngine;
        dsc = _dsc;
        (wethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();
        INITIAL_WETH_PRICE = config.INITIAL_WETH_PRICE();
        ADDITIONAL_PRICE_PRECISION = dscEngine.ADDITIONAL_PRICE_PRECISION();
        PRECISION = dscEngine.PRECISION();
        LIQUIDATION_BONUS = dscEngine.getLIQUIDATIONBONUS();
        LIQUIDATION_PRECISION = dscEngine.getLIQUIDATIONPRECISION();

        ERC20Mock(weth).mint(user, STARING_ERC20_BALANCE);
    }

    ////////////////////////
    // constructor Tests //
    //////////////////////
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses = [makeAddr("0x1")];
        priceFeedAddresses = [makeAddr("0x2"), makeAddr("0x3")];
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMismatched.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    ////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15 ether;
        uint256 priceInUsd = dscEngine.getUsdValue(weth, ethAmount);
        assert(priceInUsd == (ethAmount * uint256(INITIAL_WETH_PRICE) * ADDITIONAL_PRICE_PRECISION) / PRECISION);
    }

    function testGetTokenAnmountFromUSD() public view {
        uint256 dscAmount = 10;
        uint256 tokenAmount = dscEngine.getTokenAnmountFromUSD(weth, dscAmount);
        assert(tokenAmount == (dscAmount * PRECISION) / (uint256(INITIAL_WETH_PRICE) * ADDITIONAL_PRICE_PRECISION));
    }

    //////////////////////////////
    // despositCollateral Tests //
    //////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfTokenNotAllowed() public {
        vm.startPrank(user);
        ERC20Mock wsol = new ERC20Mock();
        ERC20Mock(wsol).mint(user, STARING_ERC20_BALANCE);
        ERC20Mock(wsol).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TokenDisallowed.selector);
        dscEngine.depositCollateral(address(wsol), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier UserERC20Approve() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_DSCMINTED);
        _;
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        _;
    }

    function testDepositCollateralSuccess() public depositedCollateral {
        (uint256 totalDSCMinted, uint256 totalCallateralValueInUSD) = dscEngine.getAccountInformation();
        assert(totalDSCMinted == 0);
        assert(
            totalCallateralValueInUSD
                == (AMOUNT_COLLATERAL * uint256(INITIAL_WETH_PRICE) * ADDITIONAL_PRICE_PRECISION) / PRECISION
        );
        vm.stopPrank();
    }

    //////////////////
    //  mintDSC    //
    ////////////////

    function testMintDSCTooMuch() public depositedCollateral {
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 2.5e17));
        dscEngine.mintDSC(40000 ether);
    }

    function testMintDSCSuccess() public depositedCollateral {
        dscEngine.mintDSC(5000 ether);
    }

    //////////////////////////////
    // redeemCollateral Tests  //
    //////////////////////////////

    function testRevertIfRedeemCollateralZero() public depositedCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfRedeemCollateralTokenNotAllowed() public depositedCollateral {
        ERC20Mock wsol = new ERC20Mock();
        vm.expectRevert(DSCEngine.DSCEngine__TokenDisallowed.selector);
        dscEngine.redeemCollateral(address(wsol), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralSuccess() public depositedCollateral {
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        (, uint256 totalCallateralValueInUSD) = dscEngine.getAccountInformation();
        assert(totalCallateralValueInUSD == 0);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDSC Tests //
    //////////////////////////////////////

    function testRevertIfDepositCollateralAndMintDSCFailedDueToBadHealthFactor() public UserERC20Approve {
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 833333333333333333));
        dscEngine.depositCollateralAndMintDSC(weth, 0.005 ether, AMOUNT_DSCMINTED);
    }

    function testDepositCollateralAndMintDSCSuccess() public UserERC20Approve {
        dscEngine.depositCollateralAndMintDSC(weth, 5 ether, AMOUNT_DSCMINTED);
    }

    ///////////////////////////////////////
    // redeemCollateralForDSC Tests     //
    //////////////////////////////////////

    modifier UserDepositCollateralAndMintDSC() {
        // 12 : 6
        dscEngine.depositCollateralAndMintDSC(weth, 0.006 ether, AMOUNT_DSCMINTED);
        _;
    }

    function testRevertIfRedeemCollateralForDSCFailedDueToBadHealthFactor()
        public
        UserERC20Approve
        UserDepositCollateralAndMintDSC
    {
        uint256 redeemDSC = 1 ether; // 1 usd
        ERC20Mock(address(dsc)).approve(address(dscEngine), redeemDSC);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 4e17));
        // 0.004 ether * 2000 = 8 usd
        // (12 - 8) : (6 - 1)
        dscEngine.redeemCollateralForDSC(weth, 0.004 ether, redeemDSC);
    }

    function testRedeemCollateralForDSCSuccess() public UserERC20Approve UserDepositCollateralAndMintDSC {
        uint256 redeemDSC = 1 ether; // 1 usd
        dsc.approve(address(dscEngine), redeemDSC);
        // 0.001 ether * 2000 = 2 usd
        // (12 - 2) : (6 - 1)
        dscEngine.redeemCollateralForDSC(weth, 0.001 ether, redeemDSC);
        (uint256 totalDSCMinted, uint256 totalCallateralValueInUSD) = dscEngine.getAccountInformation();
        assert(totalCallateralValueInUSD == 10 ether);
        assert(totalDSCMinted == 5 ether);
    }

    ///////////////////////////////////////
    // redeemCollateralForDSC Tests     //
    //////////////////////////////////////

    function testLiquidateAUserWhoseHealthFactorIsOk() public UserERC20Approve UserDepositCollateralAndMintDSC {
        address badUser = makeAddr("badUser");
        ERC20Mock(weth).mint(badUser, STARING_ERC20_BALANCE);
        vm.startPrank(badUser);
        // 12 : 6
        ERC20Mock(weth).approve(address(dscEngine), 0.006 ether);
        dscEngine.depositCollateralAndMintDSC(weth, 0.006 ether, 6 ether);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dscEngine.liquidate(weth, badUser, 10 ether);
    }

    function testLiquidateAUserWithOverCollateralToRedeem() public UserERC20Approve UserDepositCollateralAndMintDSC {
        address badUser = makeAddr("badUser");
        ERC20Mock(weth).mint(badUser, STARING_ERC20_BALANCE);
        vm.startPrank(badUser);
        // 12 : 6
        ERC20Mock(weth).approve(address(dscEngine), 0.006 ether);
        dscEngine.depositCollateralAndMintDSC(weth, 0.006 ether, 6 ether);

        // change weth price from $2000 to $1167
        // 7 : 6
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1167e8);

        uint256 totalDepositedCallateral = dscEngine.getDepositedCallateral(weth);

        vm.stopPrank();

        vm.startPrank(user);
        uint256 debtToCover = 6.45 ether;
        dsc.approve(address(dscEngine), debtToCover);
        uint256 tokenAmountFromDebtCovered = dscEngine.getTokenAnmountFromUSD(weth, debtToCover);
        // And give them a 10% bouns
        uint256 bonusCallateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCallateral;

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__CollateralOver.selector, totalDepositedCallateral, totalCollateralToRedeem
            )
        );
        dscEngine.liquidate(weth, badUser, debtToCover); // 5.45 + 10% bonus = 6 USD
        vm.stopPrank();
    }

    function testLiquidateAUserWhoseHealthFactorIsNotOk() public UserERC20Approve UserDepositCollateralAndMintDSC {
        address badUser = makeAddr("badUser");
        ERC20Mock(weth).mint(badUser, STARING_ERC20_BALANCE);
        vm.startPrank(badUser);
        // 12 : 6
        ERC20Mock(weth).approve(address(dscEngine), 0.006 ether);
        dscEngine.depositCollateralAndMintDSC(weth, 0.006 ether, 6 ether);

        // change weth price from $2000 to $1167
        // 7 : 6
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1167e8);

        uint256 beforeLiquidatedCollateral = dscEngine.getDepositedCallateral(weth);

        vm.stopPrank();

        vm.startPrank(user);
        uint256 debtToCover = 4.54 ether;
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(weth, badUser, debtToCover); // 4.54 + 10% bonus = 5 USD
        vm.stopPrank();

        vm.startPrank(badUser);
        uint256 afterLiquidatedCollateral = dscEngine.getDepositedCallateral(weth);
        uint256 tokenAmountFromDebtCovered = dscEngine.getTokenAnmountFromUSD(weth, debtToCover);
        uint256 bonusCallateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCallateral;
        assert(beforeLiquidatedCollateral - totalCollateralToRedeem == afterLiquidatedCollateral);

        vm.stopPrank();
    }

    function testHealthFactorNotImprovedAfterLiquidateAUserWhoseHealthFactorIsNotOk()
        public
        UserERC20Approve
        UserDepositCollateralAndMintDSC
    {
        address badUser = makeAddr("badUser");
        ERC20Mock(weth).mint(badUser, STARING_ERC20_BALANCE);
        vm.startPrank(badUser);
        // 12 : 6
        ERC20Mock(weth).approve(address(dscEngine), 0.006 ether);
        dscEngine.depositCollateralAndMintDSC(weth, 0.006 ether, 6 ether);

        // change weth price from $2000 to $1167
        // 5 : 6
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(833e8);

        vm.stopPrank();

        vm.startPrank(user);
        uint256 debtToCover = 0.91 ether;
        dsc.approve(address(dscEngine), debtToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dscEngine.liquidate(weth, badUser, debtToCover); // 0.91 + 10% bonus = 1 USD
        vm.stopPrank();
    }

    function testRevertBreakHealthFactorAfterLiquidateAUserWhoseHealthFactorIsNotOk()
        public
        UserERC20Approve
        UserDepositCollateralAndMintDSC
    {
        address badUser = makeAddr("badUser");
        ERC20Mock(weth).mint(badUser, STARING_ERC20_BALANCE);
        vm.startPrank(badUser);
        // 12 : 6
        ERC20Mock(weth).approve(address(dscEngine), 0.006 ether);
        dscEngine.depositCollateralAndMintDSC(weth, 0.006 ether, 6 ether);

        // change weth price from $2000 to $1167
        // 7 : 6
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1167e8);

        vm.stopPrank();

        vm.startPrank(user);
        uint256 debtToCover = 0.91 ether;
        dsc.approve(address(dscEngine), debtToCover);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, 687819253438113948));
        dscEngine.liquidate(weth, badUser, debtToCover); // 0.91 + 10% bonus = 1 USD
        vm.stopPrank();
    }
}
