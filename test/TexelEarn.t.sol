// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TexelEarn} from "../src/TexelEarn.sol";
import {FalseToken, MockStockToken, NoReturnToken, ReentrantToken} from "./mocks/EarnTokens.sol";

/// @dev Trees for the tests: the leaf of `TexelEarn`, and a tree that hashes each sorted pair as
/// MerkleProof of OpenZeppelin does. Its layout differs from the StandardMerkleTree, which the
/// contract does not need; the vector test checks a tree of OpenZeppelin itself.
library EarnTree {
    function leaf(address account, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            layer = _up(layer);
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        bytes32[] memory path = new bytes32[](64);
        uint256 length = 0;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < layer.length) path[length++] = layer[sibling];
            layer = _up(layer);
            index /= 2;
        }
        bytes32[] memory out = new bytes32[](length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = path[i];
        }
        return out;
    }

    /// @dev The layer above: each pair hashed, and a last node without a pair moved up as it is.
    function _up(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((layer.length + 1) / 2);
        for (uint256 i = 0; i < next.length; ++i) {
            uint256 left = 2 * i;
            next[i] = left + 1 < layer.length ? hashPair(layer[left], layer[left + 1]) : layer[left];
        }
    }
}

/// @dev What the tests share: a token, the contract, four wallets, and the rounds.
abstract contract EarnSetup is Test {
    /// @dev A book of one round: each wallet with its amount over every round.
    struct Book {
        address[] accounts;
        uint256[] cumulative;
        bytes32[] leaves;
        bytes32 root;
        uint256 total;
    }

    address internal owner = makeAddr("treasury");
    address internal publisher = makeAddr("gas wallet");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function _book(address[] memory accounts, uint256[] memory cumulative) internal pure returns (Book memory b) {
        b.accounts = accounts;
        b.cumulative = cumulative;
        b.leaves = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; ++i) {
            b.leaves[i] = EarnTree.leaf(accounts[i], cumulative[i]);
            b.total += cumulative[i];
        }
        b.root = EarnTree.root(b.leaves);
    }

    function _proof(Book memory b, uint256 index) internal pure returns (bytes32[] memory) {
        return EarnTree.proof(b.leaves, index);
    }

    function _wallets() internal view returns (address[] memory list) {
        list = new address[](4);
        list[0] = alice;
        list[1] = bob;
        list[2] = carol;
        list[3] = dave;
    }

    function _amounts(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory list) {
        list = new uint256[](4);
        list[0] = a;
        list[1] = b;
        list[2] = c;
        list[3] = d;
    }

    /// @dev Publishes the next round of a book, 1000 blocks after the round before. The reads
    /// come first, since a prank holds for the next call only.
    function _publish(TexelEarn earn, Book memory b) internal {
        uint64 number = earn.round() + 1;
        uint64 last = earn.endBlock() + 1000;
        vm.prank(publisher);
        earn.publish(number, b.root, b.total, last);
    }
}

contract TexelEarnTest is EarnSetup {
    event Published(uint64 indexed round, bytes32 root, uint256 allocated, uint256 added, uint64 endBlock);
    event Claimed(address indexed account, uint256 amount, uint256 cumulative);
    event PublisherSet(address indexed publisher);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    uint256 internal constant NVDA = 1e18;

    MockStockToken internal nvda;
    TexelEarn internal earn;

    function setUp() public {
        nvda = new MockStockToken();
        earn = new TexelEarn(address(nvda), owner, publisher);
    }

    /// @dev Round one: 10 NVDA for alice, bob, carol, and dave, funded in full.
    function _firstRound() internal returns (Book memory b) {
        b = _book(_wallets(), _amounts(4 * NVDA, 3 * NVDA, 2 * NVDA, 1 * NVDA));
        nvda.mint(address(earn), b.total);
        _publish(earn, b);
    }

    // The deploy

    function test_constructorSetsTheRoles() public view {
        assertEq(earn.reward(), address(nvda));
        assertEq(earn.owner(), owner);
        assertEq(earn.publisher(), publisher);
        assertEq(earn.round(), 0);
        assertEq(earn.root(), bytes32(0));
    }

    function test_constructorRefusesAZeroOwnerOrPublisher() public {
        vm.expectRevert(TexelEarn.ZeroAddress.selector);
        new TexelEarn(address(nvda), address(0), publisher);
        vm.expectRevert(TexelEarn.ZeroAddress.selector);
        new TexelEarn(address(nvda), owner, address(0));
    }

    function test_constructorRefusesARewardWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.NotAContract.selector, alice));
        new TexelEarn(alice, owner, publisher);
    }

    // Publishing a round

    function test_publishSetsTheRound() public {
        Book memory b = _book(_wallets(), _amounts(4 * NVDA, 3 * NVDA, 2 * NVDA, 1 * NVDA));
        nvda.mint(address(earn), b.total);
        vm.expectEmit(address(earn));
        emit Published(1, b.root, 10 * NVDA, 10 * NVDA, 5000);
        vm.prank(publisher);
        earn.publish(1, b.root, b.total, 5000);
        assertEq(earn.round(), 1);
        assertEq(earn.root(), b.root);
        assertEq(earn.allocated(), 10 * NVDA);
        assertEq(earn.endBlock(), 5000);
        assertEq(earn.surplus(), 0);
    }

    function test_onlyThePublisherPublishes() public {
        nvda.mint(address(earn), NVDA);
        vm.expectRevert(TexelEarn.NotPublisher.selector);
        vm.prank(owner);
        earn.publish(1, keccak256("root"), NVDA, 1);
    }

    function test_publishTakesOnlyTheNextNumber() public {
        nvda.mint(address(earn), NVDA);
        vm.startPrank(publisher);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.WrongRound.selector, 1, 0));
        earn.publish(0, keccak256("root"), NVDA, 1);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.WrongRound.selector, 1, 2));
        earn.publish(2, keccak256("root"), NVDA, 1);
        earn.publish(1, keccak256("root"), NVDA, 1);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.WrongRound.selector, 2, 1));
        earn.publish(1, keccak256("root"), NVDA, 2);
        vm.stopPrank();
    }

    function test_publishRefusesAZeroRoot() public {
        vm.expectRevert(TexelEarn.ZeroRoot.selector);
        vm.prank(publisher);
        earn.publish(1, bytes32(0), 0, 1);
    }

    function test_publishTakesOnlyALaterEndBlock() public {
        nvda.mint(address(earn), NVDA);
        vm.startPrank(publisher);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.EndBlockNotAfter.selector, 0, 0));
        earn.publish(1, keccak256("root"), NVDA, 0);
        earn.publish(1, keccak256("root"), NVDA, 100);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.EndBlockNotAfter.selector, 100, 100));
        earn.publish(2, keccak256("next"), NVDA, 100);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.EndBlockNotAfter.selector, 100, 99));
        earn.publish(2, keccak256("next"), NVDA, 99);
        vm.stopPrank();
    }

    function test_publishNeverLowersTheAllocation() public {
        _firstRound();
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.AllocationDecreased.selector, 10 * NVDA, 10 * NVDA - 1));
        vm.prank(publisher);
        earn.publish(2, keccak256("next"), 10 * NVDA - 1, 5000);
    }

    function test_publishNeedsTheNvdaThatTheRootHolds() public {
        nvda.mint(address(earn), 5 * NVDA);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.Unfunded.selector, 5 * NVDA + 1, 5 * NVDA));
        vm.prank(publisher);
        earn.publish(1, keccak256("root"), 5 * NVDA + 1, 1);
    }

    function test_aRoundCountsTheNvdaClaimedBefore() public {
        Book memory first = _firstRound();
        vm.prank(alice);
        earn.claim(alice, 4 * NVDA, _proof(first, 0));
        // The contract holds 6 NVDA; a root of 16 NVDA with 4 claimed needs 12.
        nvda.mint(address(earn), 6 * NVDA - 1);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.Unfunded.selector, 12 * NVDA, 12 * NVDA - 1));
        vm.prank(publisher);
        earn.publish(2, keccak256("next"), 16 * NVDA, 5000);
        nvda.mint(address(earn), 1);
        vm.prank(publisher);
        earn.publish(2, keccak256("next"), 16 * NVDA, 5000);
        assertEq(earn.surplus(), 0);
    }

    function test_aRoundMayMoveNvdaBetweenWalletsWithTheSameTotal() public {
        _firstRound();
        Book memory fixedBook = _book(_wallets(), _amounts(3 * NVDA, 4 * NVDA, 2 * NVDA, 1 * NVDA));
        vm.expectEmit(address(earn));
        emit Published(2, fixedBook.root, 10 * NVDA, 0, 2000);
        _publish(earn, fixedBook);
        vm.prank(bob);
        assertEq(earn.claim(bob, 4 * NVDA, _proof(fixedBook, 1)), 4 * NVDA);
    }

    // Claims

    function test_claimPaysTheWalletOfTheLeaf() public {
        Book memory b = _firstRound();
        vm.expectEmit(address(earn));
        emit Claimed(bob, 3 * NVDA, 3 * NVDA);
        vm.prank(bob);
        uint256 paid = earn.claim(bob, 3 * NVDA, _proof(b, 1));
        assertEq(paid, 3 * NVDA);
        assertEq(nvda.balanceOf(bob), 3 * NVDA);
        assertEq(earn.claimed(bob), 3 * NVDA);
        assertEq(earn.claimedTotal(), 3 * NVDA);
        assertEq(nvda.balanceOf(address(earn)), 7 * NVDA);
    }

    function test_anyoneMayClaimAndTheNvdaGoesToTheWallet() public {
        Book memory b = _firstRound();
        vm.prank(publisher);
        earn.claim(carol, 2 * NVDA, _proof(b, 2));
        assertEq(nvda.balanceOf(carol), 2 * NVDA);
        assertEq(nvda.balanceOf(publisher), 0);
    }

    function test_aSecondClaimOfTheSameRoundPaysNothing() public {
        Book memory b = _firstRound();
        earn.claim(alice, 4 * NVDA, _proof(b, 0));
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.NothingToClaim.selector, alice));
        earn.claim(alice, 4 * NVDA, _proof(b, 0));
    }

    function test_claimRefusesALeafThatIsNotInTheRoot() public {
        Book memory b = _firstRound();
        bytes32[] memory proof = _proof(b, 0);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, alice));
        earn.claim(alice, 4 * NVDA + 1, proof);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, bob));
        earn.claim(bob, 4 * NVDA, proof);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, alice));
        earn.claim(alice, 4 * NVDA, new bytes32[](0));
    }

    function test_claimRefusesAnInnerNodeAsALeaf() public {
        Book memory b = _firstRound();
        // The node above alice and bob is not a leaf; no pair of wallet and amount hashes to it.
        bytes32 inner = EarnTree.hashPair(b.leaves[0], b.leaves[1]);
        bytes32[] memory rest = new bytes32[](1);
        rest[0] = EarnTree.hashPair(b.leaves[2], b.leaves[3]);
        assertEq(EarnTree.hashPair(inner, rest[0]), b.root);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, address(uint160(uint256(inner)))));
        earn.claim(address(uint160(uint256(inner))), uint256(inner), rest);
    }

    function test_nothingIsClaimedBeforeTheFirstRound() public {
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, alice));
        earn.claim(alice, 0, new bytes32[](0));
    }

    function test_aLaterRoundPaysOnlyWhatIsNew() public {
        Book memory first = _firstRound();
        earn.claim(alice, 4 * NVDA, _proof(first, 0));
        Book memory second = _book(_wallets(), _amounts(6 * NVDA, 4 * NVDA, 2 * NVDA, 3 * NVDA));
        nvda.mint(address(earn), 5 * NVDA);
        _publish(earn, second);
        assertEq(earn.claim(alice, 6 * NVDA, _proof(second, 0)), 2 * NVDA);
        assertEq(earn.claim(bob, 4 * NVDA, _proof(second, 1)), 4 * NVDA);
        assertEq(nvda.balanceOf(alice), 6 * NVDA);
        assertEq(nvda.balanceOf(bob), 4 * NVDA);
    }

    function test_aProofOfAnOlderRootFails() public {
        Book memory first = _firstRound();
        Book memory second = _book(_wallets(), _amounts(5 * NVDA, 3 * NVDA, 2 * NVDA, 1 * NVDA));
        nvda.mint(address(earn), NVDA);
        _publish(earn, second);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, alice));
        earn.claim(alice, 4 * NVDA, _proof(first, 0));
    }

    function test_claimManyPaysEveryWalletAndSkipsThosePaid() public {
        Book memory b = _firstRound();
        earn.claim(bob, 3 * NVDA, _proof(b, 1));
        TexelEarn.Claim[] memory claims = new TexelEarn.Claim[](4);
        for (uint256 i = 0; i < 4; ++i) {
            claims[i] = TexelEarn.Claim(b.accounts[i], b.cumulative[i], _proof(b, i));
        }
        vm.prank(publisher);
        assertEq(earn.claimMany(claims), 7 * NVDA);
        assertEq(nvda.balanceOf(alice), 4 * NVDA);
        assertEq(nvda.balanceOf(bob), 3 * NVDA);
        assertEq(nvda.balanceOf(carol), 2 * NVDA);
        assertEq(nvda.balanceOf(dave), 1 * NVDA);
        assertEq(nvda.balanceOf(address(earn)), 0);
        assertEq(earn.claimMany(claims), 0);
    }

    function test_claimManyFailsWholeOnABadProof() public {
        Book memory b = _firstRound();
        TexelEarn.Claim[] memory claims = new TexelEarn.Claim[](2);
        claims[0] = TexelEarn.Claim(alice, 4 * NVDA, _proof(b, 0));
        claims[1] = TexelEarn.Claim(bob, 4 * NVDA, _proof(b, 1));
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.InvalidProof.selector, bob));
        earn.claimMany(claims);
        assertEq(nvda.balanceOf(alice), 0);
    }

    function test_claimsNeverPayMoreThanTheAllocation() public {
        // A wrong root that holds 12 NVDA while it says 10: the claims stop at 10, and the
        // NVDA of the next round stays where it is.
        Book memory b = _book(_wallets(), _amounts(4 * NVDA, 3 * NVDA, 2 * NVDA, 3 * NVDA));
        nvda.mint(address(earn), 20 * NVDA);
        vm.prank(publisher);
        earn.publish(1, b.root, 10 * NVDA, 1);
        earn.claim(alice, 4 * NVDA, _proof(b, 0));
        earn.claim(bob, 3 * NVDA, _proof(b, 1));
        earn.claim(carol, 2 * NVDA, _proof(b, 2));
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.OverAllocated.selector, 12 * NVDA, 10 * NVDA));
        earn.claim(dave, 3 * NVDA, _proof(b, 3));
        assertEq(earn.surplus(), 10 * NVDA);
    }

    function test_aWalletThatTheTokenBlocksGetsNothingAndKeepsItsClaim() public {
        Book memory b = _firstRound();
        nvda.setBlocked(carol, true);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountBlocked.selector, carol));
        earn.claim(carol, 2 * NVDA, _proof(b, 2));
        assertEq(earn.claimed(carol), 0);
        assertEq(earn.claimedTotal(), 0);
        nvda.setBlocked(carol, false);
        assertEq(earn.claim(carol, 2 * NVDA, _proof(b, 2)), 2 * NVDA);
    }

    function test_aPausedTokenStopsClaimsWithoutLoss() public {
        Book memory b = _firstRound();
        nvda.setPaused(true);
        vm.expectRevert(MockStockToken.TokenPaused.selector);
        earn.claim(alice, 4 * NVDA, _proof(b, 0));
        nvda.setPaused(false);
        assertEq(earn.claim(alice, 4 * NVDA, _proof(b, 0)), 4 * NVDA);
    }

    function test_aBurnByTheIssuerStopsTheLastClaimsAndTheNextRound() public {
        Book memory b = _firstRound();
        nvda.adminBurn(address(earn), 2 * NVDA);
        earn.claim(alice, 4 * NVDA, _proof(b, 0));
        earn.claim(bob, 3 * NVDA, _proof(b, 1));
        vm.expectRevert(
            abi.encodeWithSelector(MockStockToken.InsufficientBalance.selector, address(earn), NVDA, 2 * NVDA)
        );
        earn.claim(carol, 2 * NVDA, _proof(b, 2));
        assertEq(earn.surplus(), 0);
        Book memory next = _book(_wallets(), _amounts(4 * NVDA, 3 * NVDA, 2 * NVDA, 2 * NVDA));
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.Unfunded.selector, 4 * NVDA, NVDA));
        vm.prank(publisher);
        earn.publish(2, next.root, next.total, 5000);
    }

    function test_aTokenThatReturnsFalseFailsTheClaim() public {
        FalseToken token = new FalseToken();
        TexelEarn falseEarn = new TexelEarn(address(token), owner, publisher);
        Book memory b = _book(_wallets(), _amounts(NVDA, NVDA, NVDA, NVDA));
        token.mint(address(falseEarn), b.total);
        _publish(falseEarn, b);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.TransferFailed.selector, address(token), alice, NVDA));
        falseEarn.claim(alice, NVDA, _proof(b, 0));
        assertEq(falseEarn.claimed(alice), 0);
    }

    function test_aClaimFromInsideATransferPaysNothingMore() public {
        ReentrantToken token = new ReentrantToken();
        TexelEarn reentrant = new TexelEarn(address(token), owner, publisher);
        Book memory b = _book(_wallets(), _amounts(4 * NVDA, 3 * NVDA, 2 * NVDA, 1 * NVDA));
        token.mint(address(reentrant), 20 * NVDA);
        _publish(reentrant, b);
        token.arm(address(reentrant), alice, 4 * NVDA, _proof(b, 0));
        reentrant.claim(alice, 4 * NVDA, _proof(b, 0));
        assertTrue(token.entered());
        assertFalse(token.innerPaid());
        assertEq(token.balanceOf(alice), 4 * NVDA);
        assertEq(reentrant.claimedTotal(), 4 * NVDA);
    }

    // The surplus and the owner

    function test_surplusIsTheNvdaThatNoRootHolds() public {
        Book memory b = _firstRound();
        assertEq(earn.surplus(), 0);
        nvda.mint(address(earn), 7 * NVDA);
        assertEq(earn.surplus(), 7 * NVDA);
        earn.claim(alice, 4 * NVDA, _proof(b, 0));
        assertEq(earn.surplus(), 7 * NVDA);
    }

    function test_theOwnerTakesBackOnlyTheSurplusOfNvda() public {
        _firstRound();
        nvda.mint(address(earn), 3 * NVDA);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.OverSurplus.selector, 3 * NVDA + 1, 3 * NVDA));
        earn.recover(address(nvda), owner, 3 * NVDA + 1);
        vm.expectEmit(address(earn));
        emit Recovered(address(nvda), owner, 3 * NVDA);
        earn.recover(address(nvda), owner, 3 * NVDA);
        vm.stopPrank();
        assertEq(nvda.balanceOf(owner), 3 * NVDA);
        assertEq(nvda.balanceOf(address(earn)), 10 * NVDA);
    }

    function test_theOwnerTakesBackAnyOtherTokenInFull() public {
        NoReturnToken stray = new NoReturnToken();
        stray.mint(address(earn), 5 * NVDA);
        vm.prank(owner);
        earn.recover(address(stray), owner, 5 * NVDA);
        assertEq(stray.balanceOf(owner), 5 * NVDA);
    }

    function test_onlyTheOwnerRecovers() public {
        nvda.mint(address(earn), NVDA);
        vm.expectRevert(TexelEarn.NotOwner.selector);
        vm.prank(publisher);
        earn.recover(address(nvda), publisher, NVDA);
    }

    function test_recoverNeedsAnAddress() public {
        nvda.mint(address(earn), NVDA);
        vm.expectRevert(TexelEarn.ZeroAddress.selector);
        vm.prank(owner);
        earn.recover(address(nvda), address(0), NVDA);
    }

    function test_recoverRefusesATokenWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(TexelEarn.TransferFailed.selector, alice, owner, 1));
        vm.prank(owner);
        earn.recover(alice, owner, 1);
    }

    function test_theOwnerNamesThePublisherAndCanStopTheRounds() public {
        vm.expectRevert(TexelEarn.NotOwner.selector);
        earn.setPublisher(alice);
        vm.expectEmit(address(earn));
        emit PublisherSet(address(0));
        vm.prank(owner);
        earn.setPublisher(address(0));
        nvda.mint(address(earn), NVDA);
        vm.expectRevert(TexelEarn.NotPublisher.selector);
        vm.prank(publisher);
        earn.publish(1, keccak256("root"), NVDA, 1);
    }

    function test_claimsGoOnWhenTheRoundsStop() public {
        Book memory b = _firstRound();
        vm.prank(owner);
        earn.setPublisher(address(0));
        assertEq(earn.claim(dave, NVDA, _proof(b, 3)), NVDA);
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.expectRevert(TexelEarn.NotOwner.selector);
        earn.transferOwnership(alice);
        vm.expectEmit(address(earn));
        emit OwnershipTransferStarted(owner, alice);
        vm.prank(owner);
        earn.transferOwnership(alice);
        assertEq(earn.owner(), owner);
        vm.expectRevert(TexelEarn.NotPendingOwner.selector);
        vm.prank(bob);
        earn.acceptOwnership();
        vm.expectEmit(address(earn));
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        earn.acceptOwnership();
        assertEq(earn.owner(), alice);
        assertEq(earn.pendingOwner(), address(0));
    }

    function test_aZeroPendingOwnerCancelsTheTransfer() public {
        vm.startPrank(owner);
        earn.transferOwnership(alice);
        earn.transferOwnership(address(0));
        vm.stopPrank();
        vm.expectRevert(TexelEarn.NotPendingOwner.selector);
        vm.prank(alice);
        earn.acceptOwnership();
    }

    /// @dev Three wallets through the StandardMerkleTree of OpenZeppelin (7 Nov 2026);
    /// the TypeScript tests of the Earn worker check the same root.
    function test_aTreeOfOpenZeppelinPaysEveryWallet() public {
        address[3] memory wallets = [
            0x1111111111111111111111111111111111111111,
            0x2222222222222222222222222222222222222222,
            0x3333333333333333333333333333333333333333
        ];
        uint256[3] memory amounts = [uint256(1e18), 2.5e18, 7];
        bytes32[][3] memory proofs;
        proofs[0] = new bytes32[](2);
        proofs[0][0] = 0xb92c48e9d7abe27fd8dfd6b5dfdbfb1c9a463f80c712b66f3a5180a090cccafc;
        proofs[0][1] = 0xbe3b42a05702c04893d953884f1140495cc5b2fea835e19e0bb1d150bd5f9c6a;
        proofs[1] = new bytes32[](2);
        proofs[1][0] = 0xb38ec842db1cd54e5e5ce48491f1a404551e9726ebda349d0478e189e0996dd4;
        proofs[1][1] = 0xbe3b42a05702c04893d953884f1140495cc5b2fea835e19e0bb1d150bd5f9c6a;
        proofs[2] = new bytes32[](1);
        proofs[2][0] = 0x5aafa111a8add43a7c11e121dc72ce8d1e138114e148625f6411b4cf96664fd7;
        nvda.mint(address(earn), 3.5e18 + 7);
        vm.prank(publisher);
        earn.publish(1, 0xb4a5c97cfe2f66111be274ba6bd866fd6a17ebab73f0bb2167fa7008ea95f439, 3.5e18 + 7, 1);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(earn.claim(wallets[i], amounts[i], proofs[i]), amounts[i]);
            assertEq(nvda.balanceOf(wallets[i]), amounts[i]);
        }
        assertEq(nvda.balanceOf(address(earn)), 0);
    }

    function test_theContractRefusesEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(earn).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // Fuzz

    /// @dev Two rounds of any amounts: after every claim each wallet holds its amount, and the
    /// contract keeps exactly the NVDA that no root holds.
    function testFuzz_twoRoundsPayEveryWalletItsAmount(uint96[4] calldata first, uint96[4] calldata added, uint96 extra)
        public
    {
        uint256[] memory one = _amounts(first[0], first[1], first[2], first[3]);
        uint256[] memory two = _amounts(
            uint256(first[0]) + added[0],
            uint256(first[1]) + added[1],
            uint256(first[2]) + added[2],
            uint256(first[3]) + added[3]
        );
        Book memory b1 = _book(_wallets(), one);
        Book memory b2 = _book(_wallets(), two);
        vm.assume(b1.total > 0);
        nvda.mint(address(earn), b1.total);
        _publish(earn, b1);
        for (uint256 i = 0; i < 4; i += 2) {
            if (one[i] > 0) earn.claim(b1.accounts[i], one[i], _proof(b1, i));
        }
        nvda.mint(address(earn), b2.total - b1.total + extra);
        _publish(earn, b2);
        for (uint256 i = 0; i < 4; ++i) {
            uint256 owed = two[i] - earn.claimed(b2.accounts[i]);
            if (owed > 0) assertEq(earn.claim(b2.accounts[i], two[i], _proof(b2, i)), owed);
            assertEq(nvda.balanceOf(b2.accounts[i]), two[i]);
        }
        assertEq(earn.claimedTotal(), b2.total);
        assertEq(nvda.balanceOf(address(earn)), extra);
        assertEq(earn.surplus(), extra);
    }
}

/// @dev Random rounds, claims, and recoveries for the invariant test. Each round adds NVDA to
/// the four wallets from the surplus of the contract, and the book grows by those amounts.
contract EarnHandler is EarnSetup {
    TexelEarn public earn;
    MockStockToken public nvda;
    address public sink = makeAddr("sink");

    uint256[] internal cumulative;
    uint256 public lastAllocated;
    bool public allocationWentDown;

    constructor(TexelEarn earn_, MockStockToken nvda_, address publisher_, address owner_) {
        earn = earn_;
        nvda = nvda_;
        publisher = publisher_;
        owner = owner_;
        cumulative = _amounts(0, 0, 0, 0);
    }

    function fund(uint256 amount) external {
        nvda.mint(address(earn), bound(amount, 0, 1e24));
    }

    function publishRound(uint256[4] calldata shares) external {
        uint256 surplus = earn.surplus();
        uint256[] memory next = new uint256[](4);
        uint256 left = surplus;
        for (uint256 i = 0; i < 4; ++i) {
            uint256 add = bound(shares[i], 0, left);
            left -= add;
            next[i] = cumulative[i] + add;
        }
        Book memory b = _book(_wallets(), next);
        if (b.total == 0) return;
        _publish(earn, b);
        cumulative = next;
        if (earn.allocated() < lastAllocated) allocationWentDown = true;
        lastAllocated = earn.allocated();
    }

    function claim(uint256 index) external {
        if (earn.round() == 0) return;
        index = bound(index, 0, 3);
        Book memory b = _book(_wallets(), cumulative);
        if (cumulative[index] > earn.claimed(b.accounts[index])) {
            earn.claim(b.accounts[index], cumulative[index], _proof(b, index));
        }
    }

    function claimAll() external {
        if (earn.round() == 0) return;
        Book memory b = _book(_wallets(), cumulative);
        TexelEarn.Claim[] memory claims = new TexelEarn.Claim[](4);
        for (uint256 i = 0; i < 4; ++i) {
            claims[i] = TexelEarn.Claim(b.accounts[i], b.cumulative[i], _proof(b, i));
        }
        earn.claimMany(claims);
    }

    function recoverSurplus(uint256 amount) external {
        amount = bound(amount, 0, earn.surplus());
        vm.prank(owner);
        earn.recover(address(nvda), sink, amount);
    }

    function bookTotal() external view returns (uint256 total) {
        for (uint256 i = 0; i < 4; ++i) {
            total += cumulative[i];
        }
    }

    function wallets() external view returns (address[] memory) {
        return _wallets();
    }
}

contract TexelEarnInvariantTest is Test {
    MockStockToken internal nvda;
    TexelEarn internal earn;
    EarnHandler internal handler;

    function setUp() public {
        nvda = new MockStockToken();
        address owner = makeAddr("treasury");
        address publisher = makeAddr("gas wallet");
        earn = new TexelEarn(address(nvda), owner, publisher);
        handler = new EarnHandler(earn, nvda, publisher, owner);
        bytes4[] memory actions = new bytes4[](5);
        actions[0] = EarnHandler.fund.selector;
        actions[1] = EarnHandler.publishRound.selector;
        actions[2] = EarnHandler.claim.selector;
        actions[3] = EarnHandler.claimAll.selector;
        actions[4] = EarnHandler.recoverSurplus.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_theNvdaOfTheWalletsIsAlwaysHeld() public view {
        assertLe(earn.claimedTotal(), earn.allocated());
        assertGe(nvda.balanceOf(address(earn)), earn.allocated() - earn.claimedTotal());
        assertFalse(handler.allocationWentDown());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_everyClaimWentToItsWallet() public view {
        address[] memory wallets = handler.wallets();
        uint256 paid;
        for (uint256 i = 0; i < wallets.length; ++i) {
            assertEq(nvda.balanceOf(wallets[i]), earn.claimed(wallets[i]));
            paid += earn.claimed(wallets[i]);
        }
        assertEq(paid, earn.claimedTotal());
        assertEq(earn.allocated(), handler.bookTotal());
    }
}

/// @dev The real NVDA of Robinhood Chain on a fork. It runs only with EARN_FORK_URL set, such as
/// EARN_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork.
contract TexelEarnForkTest is EarnSetup {
    /// @dev Tokenized NVDA of Robinhood (CHECKED 7 Nov 2026: "NVIDIA • Robinhood Token", 18 decimals).
    address internal constant NVDA_TOKEN = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// @dev The NVDA/USDG pool of Uniswap v3 at 0.05%, which held about 9,276 NVDA on 7 Nov 2026.
    address internal constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    function test_theRealNvdaGoesFromAPoolToEarnToTheWallets() public {
        string memory url = vm.envOr("EARN_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        TexelEarn earn = new TexelEarn(NVDA_TOKEN, owner, publisher);
        Book memory b = _book(_wallets(), _amounts(0.4e18, 0.3e18, 0.2e18, 0.1e18));
        vm.prank(NVDA_POOL);
        (bool ok,) = NVDA_TOKEN.call(abi.encodeWithSignature("transfer(address,uint256)", address(earn), 1e18 + 7));
        assertTrue(ok);
        _publish(earn, b);
        TexelEarn.Claim[] memory claims = new TexelEarn.Claim[](4);
        for (uint256 i = 0; i < 4; ++i) {
            claims[i] = TexelEarn.Claim(b.accounts[i], b.cumulative[i], _proof(b, i));
        }
        assertEq(earn.claimMany(claims), 1e18);
        assertEq(MockStockToken(NVDA_TOKEN).balanceOf(alice), 0.4e18);
        assertEq(MockStockToken(NVDA_TOKEN).balanceOf(dave), 0.1e18);
        assertEq(earn.surplus(), 7);
    }
}
