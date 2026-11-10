// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TexelCredits} from "../src/TexelCredits.sol";
import {FalseToken, MockStockToken, NoReturnToken} from "./mocks/EarnTokens.sol";

contract TexelCreditsTest is Test {
    event Refunded(bytes32 indexed id, address indexed token, address indexed wallet, uint256 amount);
    event Forwarded(uint256 amount);
    event Burned(uint256 amount);
    event Released(address indexed token, uint256 amount);
    event OperatorSet(address indexed operator);
    event DailyCapSet(address indexed token, uint256 cap);
    event Transfer(address indexed from, address indexed to, uint256 value);

    uint256 internal constant USDG_CAP = 1_000e6;
    uint256 internal constant TEXEL_CAP = 50_000e18;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ID = keccak256("refund 1");

    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal wallet = makeAddr("wallet");
    MockStockToken internal usdg;
    MockStockToken internal texel;
    TexelCredits internal credits;

    function setUp() public {
        usdg = new MockStockToken();
        texel = new MockStockToken();
        credits = new TexelCredits(address(usdg), address(texel), treasury, operator, USDG_CAP, TEXEL_CAP);
        _pay(usdg, 2_000e6);
        _pay(texel, 100_000e18);
    }

    /// A wallet pays as it pays anyone: one plain transfer to the contract.
    function _pay(MockStockToken token, uint256 amount) internal {
        token.mint(wallet, amount);
        vm.prank(wallet);
        assertTrue(token.transfer(address(credits), amount));
    }

    function _refund(bytes32 id, address token, address to, uint256 amount) internal {
        vm.prank(operator);
        credits.refund(id, token, to, amount);
    }

    function test_itNamesItsTokensItsTreasuryItsOperatorAndItsCaps() public view {
        assertEq(credits.usdg(), address(usdg));
        assertEq(credits.texel(), address(texel));
        assertEq(credits.treasury(), treasury);
        assertEq(credits.operator(), operator);
        assertEq(credits.dailyCap(address(usdg)), USDG_CAP);
        assertEq(credits.dailyCap(address(texel)), TEXEL_CAP);
        assertEq(credits.BURN_ADDRESS(), BURN);
    }

    function test_theDeployNamesItsOperatorAndItsCaps() public {
        vm.expectEmit(true, false, false, true);
        emit OperatorSet(operator);
        vm.expectEmit(true, false, false, true);
        emit DailyCapSet(address(usdg), USDG_CAP);
        vm.expectEmit(true, false, false, true);
        emit DailyCapSet(address(texel), TEXEL_CAP);
        new TexelCredits(address(usdg), address(texel), treasury, operator, USDG_CAP, TEXEL_CAP);
    }

    function test_noAddressCanBeZero() public {
        vm.expectRevert(TexelCredits.ZeroAddress.selector);
        new TexelCredits(address(0), address(texel), treasury, operator, USDG_CAP, TEXEL_CAP);
        vm.expectRevert(TexelCredits.ZeroAddress.selector);
        new TexelCredits(address(usdg), address(0), treasury, operator, USDG_CAP, TEXEL_CAP);
        vm.expectRevert(TexelCredits.ZeroAddress.selector);
        new TexelCredits(address(usdg), address(texel), address(0), operator, USDG_CAP, TEXEL_CAP);
        vm.expectRevert(TexelCredits.ZeroAddress.selector);
        new TexelCredits(address(usdg), address(texel), treasury, address(0), USDG_CAP, TEXEL_CAP);
    }

    function test_usdgAndTexelAreTwoTokens() public {
        vm.expectRevert(TexelCredits.SameToken.selector);
        new TexelCredits(address(usdg), address(usdg), treasury, operator, USDG_CAP, TEXEL_CAP);
    }

    function test_aPaymentStaysInTheContract() public view {
        assertEq(usdg.balanceOf(address(credits)), 2_000e6);
        assertEq(texel.balanceOf(address(credits)), 100_000e18);
    }

    function test_theOperatorRefundsUnusedCreditsInUsdg() public {
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(address(credits), wallet, 8_533_000);
        vm.expectEmit(true, true, true, true, address(credits));
        emit Refunded(ID, address(usdg), wallet, 8_533_000);
        _refund(ID, address(usdg), wallet, 8_533_000);
        assertTrue(credits.paid(ID));
        assertEq(usdg.balanceOf(wallet), 8_533_000);
        assertEq(usdg.balanceOf(address(credits)), 2_000e6 - 8_533_000);
        assertEq(credits.sentOnDay(address(usdg), credits.today()), 8_533_000);
        assertEq(credits.leftToday(address(usdg)), USDG_CAP - 8_533_000);
    }

    function test_theOperatorRefundsUnusedCreditsInTexel() public {
        vm.expectEmit(true, true, false, true, address(texel));
        emit Transfer(address(credits), wallet, 600e18);
        vm.expectEmit(true, true, true, true, address(credits));
        emit Refunded(ID, address(texel), wallet, 600e18);
        _refund(ID, address(texel), wallet, 600e18);
        assertEq(texel.balanceOf(wallet), 600e18);
        assertEq(credits.leftToday(address(texel)), TEXEL_CAP - 600e18);
        assertEq(credits.leftToday(address(usdg)), USDG_CAP);
    }

    function test_anIdPaysOnceInAnyToken() public {
        _refund(ID, address(usdg), wallet, 5e6);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.AlreadyPaid.selector, ID));
        _refund(ID, address(usdg), wallet, 5e6);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.AlreadyPaid.selector, ID));
        _refund(ID, address(texel), makeAddr("someone else"), 1);
        assertEq(usdg.balanceOf(wallet), 5e6);
        assertEq(texel.balanceOf(address(credits)), 100_000e18);
    }

    /// No one but the operator pays a refund, the treasury included.
    function testFuzz_onlyTheOperatorRefunds(address caller) public {
        vm.assume(caller != operator);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, caller));
        credits.refund(ID, address(usdg), caller, 1e6);
        assertFalse(credits.paid(ID));
        assertEq(usdg.balanceOf(address(credits)), 2_000e6);
    }

    function test_aRefundNeedsAWalletAndAnAmount() public {
        vm.startPrank(operator);
        vm.expectRevert(TexelCredits.ZeroAddress.selector);
        credits.refund(ID, address(usdg), address(0), 1e6);
        vm.expectRevert(TexelCredits.ZeroAmount.selector);
        credits.refund(ID, address(usdg), wallet, 0);
        vm.stopPrank();
        assertFalse(credits.paid(ID));
    }

    /// A refund above what the contract holds pays nothing, counts nothing, and leaves its id free.
    function test_aRefundAboveWhatTheContractHoldsFailsWhole() public {
        vm.prank(treasury);
        credits.setDailyCap(address(usdg), 5_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(MockStockToken.InsufficientBalance.selector, address(credits), 2_000e6, 2_000e6 + 1)
        );
        _refund(ID, address(usdg), wallet, 2_000e6 + 1);
        assertFalse(credits.paid(ID));
        assertEq(credits.leftToday(address(usdg)), 5_000e6);
        _refund(ID, address(usdg), wallet, 2_000e6);
        assertEq(usdg.balanceOf(wallet), 2_000e6);
    }

    function test_refundsStopAtTheDailyCapAndStartAgainTheNextDay() public {
        _refund(keccak256("a"), address(usdg), wallet, 600e6);
        _refund(keccak256("b"), address(usdg), wallet, 400e6);
        assertEq(credits.leftToday(address(usdg)), 0);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(usdg), 0));
        _refund(keccak256("c"), address(usdg), wallet, 1);
        assertFalse(credits.paid(keccak256("c")));

        vm.warp((credits.today() + 1) * 1 days);
        assertEq(credits.leftToday(address(usdg)), USDG_CAP);
        _refund(keccak256("c"), address(usdg), wallet, 1);
        assertEq(usdg.balanceOf(wallet), 1_000e6 + 1);
    }

    function test_aRefundAboveWhatIsLeftTodayNamesWhatIsLeft() public {
        _refund(keccak256("a"), address(usdg), wallet, 999e6);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(usdg), 1e6));
        _refund(keccak256("b"), address(usdg), wallet, 1e6 + 1);
    }

    /// Whatever the refunds of a day, what leaves never passes the cap, and every unit is counted.
    function testFuzz_aDayNeverSendsMoreThanItsCap(uint256 first, uint256 second, uint256 third) public {
        uint256[3] memory amounts = [bound(first, 1, 800e6), bound(second, 1, 800e6), bound(third, 1, 800e6)];
        uint256 sent;
        for (uint256 i; i < 3; ++i) {
            if (sent + amounts[i] > USDG_CAP) {
                vm.expectRevert(
                    abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(usdg), USDG_CAP - sent)
                );
                _refund(keccak256(abi.encode(i)), address(usdg), wallet, amounts[i]);
            } else {
                _refund(keccak256(abi.encode(i)), address(usdg), wallet, amounts[i]);
                sent += amounts[i];
            }
        }
        assertLe(sent, USDG_CAP);
        assertEq(usdg.balanceOf(wallet), sent);
        assertEq(credits.sentOnDay(address(usdg), credits.today()), sent);
        assertEq(usdg.balanceOf(address(credits)), 2_000e6 - sent);
    }

    /// A token sent here by mistake has no cap, so the operator cannot pay it out until the
    /// treasury gives it one.
    function test_aTokenWithNoCapCannotBeRefunded() public {
        MockStockToken other = new MockStockToken();
        other.mint(address(credits), 5e18);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(other), 0));
        _refund(ID, address(other), wallet, 1);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(0), 0));
        _refund(ID, address(0), wallet, 1);

        vm.prank(treasury);
        credits.setDailyCap(address(other), 2e18);
        _refund(ID, address(other), wallet, 2e18);
        assertEq(other.balanceOf(wallet), 2e18);
    }

    function test_theOperatorForwardsUsdgToTheTreasuryOutsideTheCap() public {
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(address(credits), treasury, 1_500e6);
        vm.expectEmit(false, false, false, true, address(credits));
        emit Forwarded(1_500e6);
        vm.prank(operator);
        credits.forward(1_500e6);
        assertEq(usdg.balanceOf(treasury), 1_500e6);
        assertEq(usdg.balanceOf(address(credits)), 500e6);
        assertEq(credits.leftToday(address(usdg)), USDG_CAP);
    }

    function testFuzz_onlyTheOperatorForwards(address caller) public {
        vm.assume(caller != operator);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, caller));
        credits.forward(1e6);
        assertEq(usdg.balanceOf(address(credits)), 2_000e6);
    }

    function test_theOperatorBurnsTexelAgainstItsCap() public {
        vm.expectEmit(true, true, false, true, address(texel));
        emit Transfer(address(credits), BURN, 400e18);
        vm.expectEmit(false, false, false, true, address(credits));
        emit Burned(400e18);
        vm.prank(operator);
        credits.burn(400e18);
        assertEq(texel.balanceOf(BURN), 400e18);
        assertEq(texel.balanceOf(address(credits)), 100_000e18 - 400e18);
        assertEq(credits.leftToday(address(texel)), TEXEL_CAP - 400e18);
    }

    function test_burnsAndRefundsOfTexelShareItsCap() public {
        vm.prank(operator);
        credits.burn(30_000e18);
        _refund(ID, address(texel), wallet, 20_000e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(texel), 0));
        credits.burn(1);
        assertEq(texel.balanceOf(BURN), 30_000e18);
        assertEq(texel.balanceOf(wallet), 20_000e18);
    }

    function testFuzz_onlyTheOperatorBurns(address caller) public {
        vm.assume(caller != operator);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, caller));
        credits.burn(1e18);
        assertEq(texel.balanceOf(BURN), 0);
    }

    function test_aForwardABurnAndAReleaseMoveMoreThanNothing() public {
        vm.startPrank(operator);
        vm.expectRevert(TexelCredits.ZeroAmount.selector);
        credits.forward(0);
        vm.expectRevert(TexelCredits.ZeroAmount.selector);
        credits.burn(0);
        vm.stopPrank();
        vm.prank(treasury);
        vm.expectRevert(TexelCredits.ZeroAmount.selector);
        credits.release(address(usdg), 0);
    }

    function test_theTreasuryTakesAnyTokenBack() public {
        MockStockToken other = new MockStockToken();
        other.mint(address(credits), 3e18);
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(address(credits), treasury, 700e6);
        vm.expectEmit(true, false, false, true, address(credits));
        emit Released(address(usdg), 700e6);
        vm.startPrank(treasury);
        credits.release(address(usdg), 700e6);
        credits.release(address(texel), 100_000e18);
        credits.release(address(other), 3e18);
        vm.stopPrank();
        assertEq(usdg.balanceOf(treasury), 700e6);
        assertEq(texel.balanceOf(treasury), 100_000e18);
        assertEq(other.balanceOf(treasury), 3e18);
        assertEq(credits.leftToday(address(usdg)), USDG_CAP);
    }

    /// No one but the treasury takes tokens back, the operator included.
    function testFuzz_onlyTheTreasuryReleases(address caller) public {
        vm.assume(caller != treasury);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotTreasury.selector, caller));
        credits.release(address(usdg), 1e6);
        assertEq(usdg.balanceOf(address(credits)), 2_000e6);
    }

    function test_theTreasurySetsANewOperator() public {
        address next = makeAddr("next gas wallet");
        vm.expectEmit(true, false, false, true, address(credits));
        emit OperatorSet(next);
        vm.prank(treasury);
        credits.setOperator(next);
        assertEq(credits.operator(), next);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, operator));
        _refund(ID, address(usdg), wallet, 1e6);
        vm.prank(next);
        credits.refund(ID, address(usdg), wallet, 1e6);
        assertEq(usdg.balanceOf(wallet), 1e6);
    }

    /// With no operator, nothing can leave but through the treasury.
    function test_theTreasuryStopsTheOperator() public {
        vm.prank(treasury);
        credits.setOperator(address(0));
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, operator));
        credits.refund(ID, address(usdg), wallet, 1e6);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, operator));
        credits.forward(1e6);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, operator));
        credits.burn(1e18);
        vm.stopPrank();
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotOperator.selector, address(0)));
        credits.forward(1e6);
        assertEq(usdg.balanceOf(address(credits)), 2_000e6);
    }

    function testFuzz_onlyTheTreasurySetsTheOperatorAndTheCaps(address caller) public {
        vm.assume(caller != treasury);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotTreasury.selector, caller));
        credits.setOperator(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.NotTreasury.selector, caller));
        credits.setDailyCap(address(usdg), type(uint256).max);
        vm.stopPrank();
        assertEq(credits.operator(), operator);
        assertEq(credits.dailyCap(address(usdg)), USDG_CAP);
    }

    function test_theTreasurySetsADailyCap() public {
        vm.expectEmit(true, false, false, true, address(credits));
        emit DailyCapSet(address(usdg), 10e6);
        vm.prank(treasury);
        credits.setDailyCap(address(usdg), 10e6);
        assertEq(credits.leftToday(address(usdg)), 10e6);
        vm.prank(treasury);
        vm.expectRevert(TexelCredits.ZeroAddress.selector);
        credits.setDailyCap(address(0), 1);
    }

    /// A cap set below what left today leaves nothing for the rest of the day.
    function test_aCapLoweredBelowWhatLeftTodayLeavesNothing() public {
        _refund(keccak256("a"), address(usdg), wallet, 300e6);
        vm.prank(treasury);
        credits.setDailyCap(address(usdg), 200e6);
        assertEq(credits.leftToday(address(usdg)), 0);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(usdg), 0));
        _refund(keccak256("b"), address(usdg), wallet, 1);
    }

    /// A zero cap stops the refunds and the burns of its token.
    function test_aZeroCapStopsItsToken() public {
        vm.prank(treasury);
        credits.setDailyCap(address(texel), 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(texel), 0));
        credits.burn(1);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.OverDailyCap.selector, address(texel), 0));
        _refund(ID, address(texel), wallet, 1);
    }

    function test_theReasonOfATokenThatRefusesComesThrough() public {
        usdg.setBlocked(wallet, true);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, wallet));
        _refund(ID, address(usdg), wallet, 1e6);
        usdg.setBlocked(wallet, false);
        usdg.setPaused(true);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        _refund(ID, address(usdg), wallet, 1e6);
        assertFalse(credits.paid(ID));
        assertEq(credits.leftToday(address(usdg)), USDG_CAP);
    }

    function test_aTokenThatReturnsNothingCountsAsSent() public {
        NoReturnToken token = new NoReturnToken();
        TexelCredits plain = new TexelCredits(address(token), address(texel), treasury, operator, 100, 100);
        token.mint(address(plain), 9);
        vm.startPrank(operator);
        plain.refund(ID, address(token), wallet, 4);
        plain.forward(3);
        vm.stopPrank();
        assertEq(token.balanceOf(wallet), 4);
        assertEq(token.balanceOf(treasury), 3);
    }

    function test_aTokenThatReturnsFalseFailsTheSend() public {
        FalseToken token = new FalseToken();
        TexelCredits falsy = new TexelCredits(address(token), address(texel), treasury, operator, 100, 100);
        token.mint(address(falsy), 7);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.TransferFailed.selector, address(token), 4));
        falsy.refund(ID, address(token), wallet, 4);
        assertFalse(falsy.paid(ID));
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(TexelCredits.TransferFailed.selector, address(token), 7));
        falsy.release(address(token), 7);
    }

    function test_anAddressWithNoCodeIsNoToken() public {
        vm.prank(treasury);
        vm.expectRevert();
        credits.release(makeAddr("no code"), 1);
    }

    function test_ethIsRefused() public {
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        (bool ok,) = address(credits).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(address(credits).balance, 0);
    }
}

/// @dev The one call of the Universal Router of Uniswap that a payment in another token makes.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev The real USDG, $TEXEL, and Universal Router of Robinhood Chain on a fork. It runs only with
/// DEPOSITS_FORK_URL set, such as DEPOSITS_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge
/// test --match-contract Fork.
contract TexelCreditsForkTest is Test {
    /// @dev USDG, the Global Dollar of Paxos (CHECKED 15 Oct 2026, 6 decimals).
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev A wallet that held about 103 million USDG on 4 Nov 2026.
    address internal constant HOLDER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    /// @dev $TEXEL (CHECKED 10 Nov 2026, 18 decimals).
    address internal constant TEXEL = 0x0DdCAb9ae04bDA0c87eCC1640636FA11e8e613E8;
    /// @dev WETH9 of Uniswap on Robinhood Chain, as WETH9() of its NonfungiblePositionManager
    /// answered on 10 Nov 2026.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev Universal Router 2.1.1 of Uniswap on Robinhood Chain, from the deployments of Uniswap
    /// (read 10 Nov 2026). Its V3 swap takes a list of the lowest prices per hop.
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    /// @dev The fee tier of the deepest WETH/USDG pool: 0.01% (about 5,410 WETH and 2.3 million USDG
    /// on 10 Nov 2026).
    uint24 internal constant FEE = 100;
    /// @dev The commands of the Universal Router: WRAP_ETH, then V3_SWAP_EXACT_IN.
    bytes internal constant WRAP_AND_SWAP = hex"0b00";
    /// @dev The address by which a command names the Universal Router itself.
    address internal constant ROUTER_ITSELF = address(2);

    function test_paymentsInUsdgEthAndTexelRefundsForwardsAndBurns() public {
        string memory url = vm.envOr("DEPOSITS_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        address treasury = makeAddr("treasury");
        address operator = makeAddr("operator");
        address payer = makeAddr("payer");
        TexelCredits credits = new TexelCredits(USDG, TEXEL, treasury, operator, 1_000e6, 50_000e18);
        MockStockToken usdg = MockStockToken(USDG);
        MockStockToken texel = MockStockToken(TEXEL);

        // USDG, in one plain transfer.
        vm.prank(HOLDER);
        (bool ok,) = USDG.call(abi.encodeWithSignature("transfer(address,uint256)", address(credits), 10e6));
        assertTrue(ok);
        assertEq(usdg.balanceOf(address(credits)), 10e6);

        // ETH, swapped to USDG in the same transaction, with the USDG sent to the contract.
        vm.deal(payer, 1 ether);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ROUTER_ITSELF, 0.01 ether);
        inputs[1] =
            abi.encode(address(credits), 0.01 ether, 1, abi.encodePacked(WETH, FEE, USDG), false, new uint256[](0));
        vm.prank(payer);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 0.01 ether}(WRAP_AND_SWAP, inputs, block.timestamp + 600);
        uint256 swapped = usdg.balanceOf(address(credits)) - 10e6;
        assertGt(swapped, 1e6);
        assertEq(usdg.balanceOf(payer), 0);

        // $TEXEL, in one plain transfer.
        deal(TEXEL, payer, 1_000e18);
        vm.prank(payer);
        assertTrue(texel.transfer(address(credits), 1_000e18));

        // A refund in USDG, the USDG of used credits to the treasury, then the $TEXEL: 400 used
        // and burned, 600 refunded.
        vm.startPrank(operator);
        credits.refund(keccak256("usdg"), USDG, payer, 8_533_000);
        credits.forward(1_467_000);
        uint256 burnedBefore = texel.balanceOf(credits.BURN_ADDRESS());
        credits.burn(400e18);
        credits.refund(keccak256("texel"), TEXEL, payer, 600e18);
        vm.stopPrank();
        assertEq(usdg.balanceOf(payer), 8_533_000);
        assertEq(usdg.balanceOf(treasury), 1_467_000);
        assertEq(texel.balanceOf(credits.BURN_ADDRESS()) - burnedBefore, 400e18);
        assertEq(texel.balanceOf(payer), 600e18);
        assertEq(texel.balanceOf(address(credits)), 0);

        // The treasury takes back what is left: the USDG of the swap.
        vm.prank(treasury);
        credits.release(USDG, swapped);
        assertEq(usdg.balanceOf(address(credits)), 0);
        assertEq(usdg.balanceOf(treasury), 1_467_000 + swapped);
    }
}
