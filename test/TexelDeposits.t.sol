// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TexelDeposits} from "../src/TexelDeposits.sol";
import {FalseToken, MockStockToken, NoReturnToken} from "./mocks/EarnTokens.sol";

contract TexelDepositsTest is Test {
    event Forwarded(address indexed token, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    address internal treasury = makeAddr("treasury");
    address internal wallet = makeAddr("wallet");
    MockStockToken internal usdg;
    TexelDeposits internal deposits;

    function setUp() public {
        usdg = new MockStockToken();
        deposits = new TexelDeposits(address(usdg), treasury);
        usdg.mint(wallet, 1_000e6);
    }

    /// A deposit as a wallet makes it: one plain transfer of USDG to the contract.
    function _deposit(uint256 amount) internal {
        vm.prank(wallet);
        assertTrue(usdg.transfer(address(deposits), amount));
    }

    function test_itNamesUsdgAndTheTreasury() public view {
        assertEq(deposits.usdg(), address(usdg));
        assertEq(deposits.treasury(), treasury);
    }

    function test_neitherAddressCanBeZero() public {
        vm.expectRevert(TexelDeposits.ZeroAddress.selector);
        new TexelDeposits(address(0), treasury);
        vm.expectRevert(TexelDeposits.ZeroAddress.selector);
        new TexelDeposits(address(usdg), address(0));
    }

    function test_aDepositIsAPlainTransferThatTheContractKeepsUntilForwarded() public {
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(wallet, address(deposits), 25e6);
        _deposit(25e6);
        assertEq(usdg.balanceOf(address(deposits)), 25e6);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    function test_forwardSendsAllTheUsdgToTheTreasury() public {
        _deposit(25e6);
        _deposit(5e6);
        vm.expectEmit(true, true, false, true, address(usdg));
        emit Transfer(address(deposits), treasury, 30e6);
        vm.expectEmit(true, false, false, true, address(deposits));
        emit Forwarded(address(usdg), 30e6);
        assertEq(deposits.forward(address(usdg)), 30e6);
        assertEq(usdg.balanceOf(address(deposits)), 0);
        assertEq(usdg.balanceOf(treasury), 30e6);
    }

    function test_forwardWithNothingHeldMovesNothing() public {
        vm.recordLogs();
        assertEq(deposits.forward(address(usdg)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    /// Whoever calls `forward`, and whatever was sent, the tokens end at the treasury.
    function testFuzz_anyoneForwardsAndOnlyTheTreasuryGetsTheTokens(address caller, uint256 amount) public {
        vm.assume(caller != treasury && caller != address(deposits));
        amount = bound(amount, 1, 1_000e6);
        _deposit(amount);
        vm.prank(caller);
        assertEq(deposits.forward(address(usdg)), amount);
        assertEq(usdg.balanceOf(treasury), amount);
        assertEq(usdg.balanceOf(caller), caller == wallet ? 1_000e6 - amount : 0);
        assertEq(usdg.balanceOf(address(deposits)), 0);
    }

    function test_anotherTokenSentByMistakeGoesToTheTreasuryToo() public {
        MockStockToken other = new MockStockToken();
        other.mint(address(deposits), 3e18);
        assertEq(deposits.forward(address(other)), 3e18);
        assertEq(other.balanceOf(treasury), 3e18);
    }

    function test_aTokenThatReturnsNothingIsForwarded() public {
        NoReturnToken token = new NoReturnToken();
        token.mint(address(deposits), 7);
        assertEq(deposits.forward(address(token)), 7);
        assertEq(token.balanceOf(treasury), 7);
    }

    function test_aTokenThatReturnsFalseFailsTheForward() public {
        FalseToken token = new FalseToken();
        token.mint(address(deposits), 7);
        vm.expectRevert(abi.encodeWithSelector(TexelDeposits.TransferFailed.selector, address(token), 7));
        deposits.forward(address(token));
    }

    function test_theReasonOfATokenThatRefusesComesThrough() public {
        _deposit(10e6);
        usdg.setBlocked(treasury, true);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, treasury));
        deposits.forward(address(usdg));
        usdg.setBlocked(treasury, false);
        usdg.setPaused(true);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        deposits.forward(address(usdg));
        assertEq(usdg.balanceOf(address(deposits)), 10e6);
    }

    function test_anAddressWithNoCodeIsNoToken() public {
        vm.expectRevert();
        deposits.forward(makeAddr("no code"));
    }

    function test_ethIsRefused() public {
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        (bool ok,) = address(deposits).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(address(deposits).balance, 0);
    }
}

/// @dev The real USDG of Robinhood Chain on a fork. It runs only with DEPOSITS_FORK_URL set, such
/// as DEPOSITS_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork.
contract TexelDepositsForkTest is Test {
    /// @dev USDG, the Global Dollar of Paxos (CHECKED 15 Oct 2026, 6 decimals).
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev A wallet that held about 103 million USDG on 4 Nov 2026.
    address internal constant HOLDER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function test_theRealUsdgGoesFromAWalletToTheContractToTheTreasury() public {
        string memory url = vm.envOr("DEPOSITS_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        address treasury = makeAddr("treasury");
        TexelDeposits deposits = new TexelDeposits(USDG, treasury);
        vm.expectEmit(true, true, false, true, USDG);
        emit Transfer(HOLDER, address(deposits), 5e6);
        vm.prank(HOLDER);
        (bool ok,) = USDG.call(abi.encodeWithSignature("transfer(address,uint256)", address(deposits), 5e6));
        assertTrue(ok);
        assertEq(deposits.forward(USDG), 5e6);
        assertEq(MockStockToken(USDG).balanceOf(treasury), 5e6);
        assertEq(MockStockToken(USDG).balanceOf(address(deposits)), 0);
    }
}
