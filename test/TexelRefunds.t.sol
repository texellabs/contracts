// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TexelRefunds} from "../src/TexelRefunds.sol";
import {FalseToken, MockStockToken, NoReturnToken} from "./mocks/EarnTokens.sol";

contract TexelRefundsTest is Test {
    event Refunded(bytes32 indexed id, address indexed wallet, uint256 amount);
    event Released(address indexed token, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal wallet = makeAddr("wallet");
    bytes32 internal constant ID = keccak256("refund 1");
    MockStockToken internal usdg;
    TexelRefunds internal refunds;

    function setUp() public {
        usdg = new MockStockToken();
        refunds = new TexelRefunds(address(usdg), treasury, operator);
        usdg.mint(treasury, 1_000e6);
        _fund(100e6);
    }

    /// The treasury keeps USDG for refunds as it pays anyone: one plain transfer.
    function _fund(uint256 amount) internal {
        vm.prank(treasury);
        assertTrue(usdg.transfer(address(refunds), amount));
    }

    function _refund(bytes32 id, address to, uint256 amount) internal {
        vm.prank(operator);
        refunds.refund(id, to, amount);
    }

    function test_itNamesUsdgTheTreasuryAndTheOperator() public view {
        assertEq(refunds.usdg(), address(usdg));
        assertEq(refunds.treasury(), treasury);
        assertEq(refunds.operator(), operator);
    }

    function test_noAddressCanBeZero() public {
        vm.expectRevert(TexelRefunds.ZeroAddress.selector);
        new TexelRefunds(address(0), treasury, operator);
        vm.expectRevert(TexelRefunds.ZeroAddress.selector);
        new TexelRefunds(address(usdg), address(0), operator);
        vm.expectRevert(TexelRefunds.ZeroAddress.selector);
        new TexelRefunds(address(usdg), treasury, address(0));
    }

    function test_theOperatorPaysARefundFromTheUsdgTheContractHolds() public {
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(address(refunds), wallet, 4_298_000);
        vm.expectEmit(true, true, false, true, address(refunds));
        emit Refunded(ID, wallet, 4_298_000);
        _refund(ID, wallet, 4_298_000);
        assertTrue(refunds.paid(ID));
        assertEq(usdg.balanceOf(wallet), 4_298_000);
        assertEq(usdg.balanceOf(address(refunds)), 100e6 - 4_298_000);
    }

    function test_anIdPaysOnce() public {
        _refund(ID, wallet, 5e6);
        vm.expectRevert(abi.encodeWithSelector(TexelRefunds.AlreadyPaid.selector, ID));
        _refund(ID, wallet, 5e6);
        vm.expectRevert(abi.encodeWithSelector(TexelRefunds.AlreadyPaid.selector, ID));
        _refund(ID, makeAddr("someone else"), 1);
        assertEq(usdg.balanceOf(wallet), 5e6);
        assertEq(usdg.balanceOf(address(refunds)), 95e6);
    }

    /// No one but the operator pays a refund, the treasury included.
    function testFuzz_onlyTheOperatorPays(address caller) public {
        vm.assume(caller != operator);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelRefunds.NotOperator.selector, caller));
        refunds.refund(ID, caller, 1e6);
        assertFalse(refunds.paid(ID));
        assertEq(usdg.balanceOf(address(refunds)), 100e6);
    }

    function test_aRefundNeedsAWalletAndAnAmount() public {
        vm.startPrank(operator);
        vm.expectRevert(TexelRefunds.ZeroAddress.selector);
        refunds.refund(ID, address(0), 1e6);
        vm.expectRevert(TexelRefunds.ZeroAmount.selector);
        refunds.refund(ID, wallet, 0);
        vm.stopPrank();
        assertFalse(refunds.paid(ID));
    }

    /// A refund above what the contract holds pays nothing and leaves its id free.
    function test_aRefundAboveTheUsdgHeldFailsWhole() public {
        vm.expectRevert(
            abi.encodeWithSelector(MockStockToken.InsufficientBalance.selector, address(refunds), 100e6, 100e6 + 1)
        );
        _refund(ID, wallet, 100e6 + 1);
        assertFalse(refunds.paid(ID));
        assertEq(usdg.balanceOf(wallet), 0);
        _refund(ID, wallet, 100e6);
        assertEq(usdg.balanceOf(wallet), 100e6);
    }

    /// Every refund pays its wallet exactly its amount, out of the USDG held, until none is left.
    function testFuzz_refundsPayExactlyTheirAmounts(uint256 first, uint256 second) public {
        first = bound(first, 1, 100e6);
        second = bound(second, 1, 100e6);
        address other = makeAddr("other");
        _refund(keccak256("first"), wallet, first);
        assertEq(usdg.balanceOf(wallet), first);
        if (first + second > 100e6) {
            vm.expectRevert();
            _refund(keccak256("second"), other, second);
            assertEq(usdg.balanceOf(other), 0);
        } else {
            _refund(keccak256("second"), other, second);
            assertEq(usdg.balanceOf(other), second);
        }
        assertEq(usdg.balanceOf(address(refunds)) + usdg.balanceOf(wallet) + usdg.balanceOf(other), 100e6);
    }

    function test_theReasonOfATokenThatRefusesComesThrough() public {
        usdg.setBlocked(wallet, true);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, wallet));
        _refund(ID, wallet, 1e6);
        usdg.setBlocked(wallet, false);
        usdg.setPaused(true);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        _refund(ID, wallet, 1e6);
        assertFalse(refunds.paid(ID));
        assertEq(usdg.balanceOf(address(refunds)), 100e6);
    }

    function test_theTreasuryTakesTheUsdgBack() public {
        _refund(ID, wallet, 10e6);
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(address(refunds), treasury, 90e6);
        vm.expectEmit(true, false, false, true, address(refunds));
        emit Released(address(usdg), 90e6);
        vm.prank(treasury);
        assertEq(refunds.release(address(usdg)), 90e6);
        assertEq(usdg.balanceOf(address(refunds)), 0);
        assertEq(usdg.balanceOf(treasury), 1_000e6 - 10e6);
    }

    /// No one but the treasury takes tokens back, the operator included.
    function testFuzz_onlyTheTreasuryReleases(address caller) public {
        vm.assume(caller != treasury);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TexelRefunds.NotTreasury.selector, caller));
        refunds.release(address(usdg));
        assertEq(usdg.balanceOf(address(refunds)), 100e6);
    }

    function test_releaseWithNothingHeldMovesNothing() public {
        vm.prank(treasury);
        refunds.release(address(usdg));
        vm.recordLogs();
        vm.prank(treasury);
        assertEq(refunds.release(address(usdg)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_anotherTokenSentByMistakeGoesBackToTheTreasury() public {
        MockStockToken other = new MockStockToken();
        other.mint(address(refunds), 3e18);
        vm.prank(treasury);
        assertEq(refunds.release(address(other)), 3e18);
        assertEq(other.balanceOf(treasury), 3e18);
    }

    function test_aTokenThatReturnsNothingCountsAsSent() public {
        NoReturnToken token = new NoReturnToken();
        TexelRefunds plain = new TexelRefunds(address(token), treasury, operator);
        token.mint(address(plain), 9);
        vm.prank(operator);
        plain.refund(ID, wallet, 4);
        assertEq(token.balanceOf(wallet), 4);
        vm.prank(treasury);
        assertEq(plain.release(address(token)), 5);
        assertEq(token.balanceOf(treasury), 5);
    }

    function test_aTokenThatReturnsFalseFailsTheSend() public {
        FalseToken token = new FalseToken();
        TexelRefunds falsy = new TexelRefunds(address(token), treasury, operator);
        token.mint(address(falsy), 7);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TexelRefunds.TransferFailed.selector, address(token), 4));
        falsy.refund(ID, wallet, 4);
        assertFalse(falsy.paid(ID));
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(TexelRefunds.TransferFailed.selector, address(token), 7));
        falsy.release(address(token));
    }

    function test_anAddressWithNoCodeIsNoToken() public {
        vm.prank(treasury);
        vm.expectRevert();
        refunds.release(makeAddr("no code"));
    }

    function test_ethIsRefused() public {
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        (bool ok,) = address(refunds).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(address(refunds).balance, 0);
    }
}

/// @dev The real USDG of Robinhood Chain on a fork. It runs only with DEPOSITS_FORK_URL set, such
/// as DEPOSITS_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork.
contract TexelRefundsForkTest is Test {
    /// @dev USDG, the Global Dollar of Paxos (CHECKED 15 Oct 2026, 6 decimals).
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev A wallet that held about 103 million USDG on 4 Nov 2026.
    address internal constant HOLDER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function test_theRealUsdgGoesFromTheContractToAWalletAndBackToTheTreasury() public {
        string memory url = vm.envOr("DEPOSITS_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        address treasury = makeAddr("treasury");
        address operator = makeAddr("operator");
        address wallet = makeAddr("wallet");
        TexelRefunds refunds = new TexelRefunds(USDG, treasury, operator);
        vm.prank(HOLDER);
        (bool ok,) = USDG.call(abi.encodeWithSignature("transfer(address,uint256)", address(refunds), 10e6));
        assertTrue(ok);
        vm.expectEmit(true, true, false, true, USDG);
        emit Transfer(address(refunds), wallet, 4_298_000);
        vm.prank(operator);
        refunds.refund(keccak256("fork"), wallet, 4_298_000);
        assertEq(MockStockToken(USDG).balanceOf(wallet), 4_298_000);
        vm.prank(treasury);
        assertEq(refunds.release(USDG), 10e6 - 4_298_000);
        assertEq(MockStockToken(USDG).balanceOf(treasury), 10e6 - 4_298_000);
        assertEq(MockStockToken(USDG).balanceOf(address(refunds)), 0);
    }
}
